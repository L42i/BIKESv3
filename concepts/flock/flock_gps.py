#!/usr/bin/env python3
"""BIKES Flocking GPS process: distance to mapped Flock cameras -> OSC for SuperCollider.

Derived from ../flock_detection/flock_gps.py. Sends to 127.0.0.1:57120:

  /flock/proximity  float  0 = no camera in range, 1 = at a camera's coordinates
  /location/flock   int    1 = inside a camera zone, 0 = outside

/location/flock goes to 1 at --radius-feet and back to 0 only past
--radius-feet + --exit-margin-feet, so GPS noise at the edge does not flicker.
It is sent on every change and again every 2 s. No fix, a stale fix, and shutdown
force it to 0.

Peer zone-entry notifications (enabled by default on bikes1 through bikes4):
  Other bikes, UDP 57122: /flock/peer/entered  STRING bike_id, STRING event_id
  Local SC, UDP 57120:   /location/flock/peer STRING bike_id, INT 1, STRING event_id
The peer message is sent only on a local 0 -> 1 zone transition, not heartbeats.
Received entries do not change this bike's own zone or get rebroadcast. Duplicate
event IDs are ignored for 60 seconds. UDP is best-effort; no delivery ACK is used.
SuperCollider must add a handler for /location/flock/peer to react to these events.
An initial valid fix inside a zone counts as an entry (also after loss of fix).

Usage:
  python3 flock_gps.py                        real GPS (u-blox on /dev/ttyACM0)
  python3 flock_gps.py --simulate walk --no-peers   walk through the first target
  python3 flock_gps.py --simulate --no-peers       read "lat,lon" lines from stdin
  python3 flock_gps.py --node 1                explicit identity for non-bike users
  python3 flock_gps.py --peer 2=10.10.10.12    override a peer IP if needed
See README.md in this folder.
"""

import argparse
from collections import OrderedDict
import getpass
import ipaddress
import math
import select
import signal
import socket
import sys
import threading
import time
import uuid

import pynmea2
import serial
from pythonosc.udp_client import SimpleUDPClient
from pythonosc.dispatcher import Dispatcher
from pythonosc.osc_server import BlockingOSCUDPServer

GPS_PORT = "/dev/ttyACM0"
BAUD_RATE = 9600
UPDATE_INTERVAL = 0.02
OSC_HOST = "127.0.0.1"
OSC_PORT = 57120
OSC_PATH = "/flock/proximity"
ZONE_PATH = "/location/flock"
PEER_PORT = 57122
PEER_ENTRY_PATH = "/flock/peer/entered"
PEER_LOCAL_PATH = "/location/flock/peer"
PEERS = {"1": "10.10.10.11", "2": "10.10.10.12",
         "3": "10.10.10.13", "4": "10.10.10.14"}
GPS_TIMEOUT = 5.0
ZERO_INTERVAL = 0.5
HEARTBEAT = 2.0
FEET = 0.3048
WALK_METERS = 60
WALK_STEP_METERS = 1.0
WALK_STEP_SECONDS = 0.2

TARGETS = [
    (33.775259, -84.395121),
    (33.77121, -84.39194),
    (33.77133, -84.39202),
    (33.77079, -84.39217),
    (33.77240, -84.39073),
    (33.77207, -84.39206),
    (33.77695, -84.39049),
    (33.77697, -84.39199),
    (33.77682, -84.39371),
    (33.77185, -84.39562),
    (33.77129, -84.39595),
    (33.77261, -84.39684),
    (33.77856, -84.40134),
    (33.77847, -84.40147),
    (33.77368, -84.40278),
    (33.77652, -84.40615),
    (33.77743, -84.40760),
    (33.78056, -84.41060),
    (33.78033, -84.41234),
    (33.78591, -84.41156),
    (33.78592, -84.41156),
    (33.78783, -84.41243),
    (33.78776, -84.41178),
]


def default_node():
    """Match the existing Ansible users; also accept a bikesN hostname."""
    for identity in (getpass.getuser(), socket.gethostname().split('.')[0]):
        if identity in {"bikes" + node for node in PEERS}:
            return identity[-1]
    return None


class PeerZoneRelay:
    """One independent listener thread, so peers work while GPS has no fix."""
    def __init__(self, node, peers, peer_port, osc_client, listen_ip="0.0.0.0"):
        self.node = node
        self.peers = dict(peers)
        self.port = peer_port
        self.osc_client = osc_client
        self.listen_ip = listen_ip
        self.clients = {peer: SimpleUDPClient(ip, peer_port)
                        for peer, ip in peers.items() if peer != node}
        self.seen = OrderedDict()  # accessed only by the single listener thread
        self.server = None
        self.thread = None

    def start(self):
        routes = Dispatcher()
        routes.map(PEER_ENTRY_PATH, self.receive, needs_reply_address=True)
        self.server = BlockingOSCUDPServer((self.listen_ip, self.port), routes)
        self.thread = threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.1},
            name="flock-peer-listener", daemon=True)
        try:
            self.thread.start()
        except Exception:
            self.server.server_close()
            self.thread = None
            raise
        print(f"Bike {self.node}: peer OSC listening on {self.listen_ip}:{self.port}; "
              f"{PEER_ENTRY_PATH} -> local {PEER_LOCAL_PATH}", flush=True)

    def entered(self):
        event_id = uuid.uuid4().hex
        for peer, client in self.clients.items():
            try:
                client.send_message(PEER_ENTRY_PATH, [self.node, event_id])
            except OSError as error:
                # A disconnected peer must not stop local GPS/speech processing.
                print(f"Could not notify bike {peer}: {error}", flush=True)
        print(f"Bike {self.node} entered a monitored zone; sent peer event {event_id}", flush=True)

    def receive(self, sender, address, *values):
        if len(values) != 2:
            return
        node, event_id = values
        if not isinstance(node, str) or node == self.node or node not in self.peers:
            return
        if sender[0] != self.peers[node]:
            return  # only accept the configured peer's address and identity
        if (not isinstance(event_id, str) or len(event_id) != 32 or
                any(char not in "0123456789abcdef" for char in event_id)):
            return
        now = time.monotonic()
        while self.seen and now - next(iter(self.seen.values())) >= 60:
            self.seen.popitem(last=False)
        key = (node, event_id)
        if key in self.seen:
            return
        try:
            self.osc_client.send_message(PEER_LOCAL_PATH, [node, 1, event_id])
        except OSError as error:
            print(f"Could not forward bike {node}'s zone entry to local SC: {error}", flush=True)
            return
        self.seen[key] = now
        if len(self.seen) > 512:
            self.seen.popitem(last=False)
        print(f"Peer bike {node} entered a monitored zone; forwarded {PEER_LOCAL_PATH} "
              f"event {event_id}", flush=True)

    def close(self):
        if self.server is not None:
            if self.thread is not None and self.thread.is_alive():
                self.server.shutdown()
                self.thread.join(timeout=1)
            self.server.server_close()
            self.server = None


def distance_meters(lat1, lon1, lat2, lon2):
    """Great-circle distance between two geographic coordinates, in meters."""
    earth_radius = 6371000
    lat1, lon1, lat2, lon2 = map(math.radians, (lat1, lon1, lat2, lon2))
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = (
        math.sin(dlat / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    )
    a = max(0.0, min(1.0, a))
    return 2 * earth_radius * math.asin(math.sqrt(a))


def proximity_value(distance, radius):
    """1 at the target, decreasing linearly to 0 at the detection boundary."""
    return max(0.0, min(1.0, 1.0 - distance / radius))


def parse_position(line):
    """Return coordinates, (None, None) for explicit no-fix, or None to skip."""
    if not line.startswith(("$GPGGA,", "$GNGGA,")):
        return None
    try:
        msg = pynmea2.parse(line)
        if not msg.gps_qual or int(msg.gps_qual) <= 0:
            return (None, None)
        if (
            not msg.lat or not msg.lon
            or msg.lat_dir not in ("N", "S")
            or msg.lon_dir not in ("E", "W")
        ):
            return None
        lat, lon = msg.latitude, msg.longitude
        if (
            math.isfinite(lat) and math.isfinite(lon)
            and -90 <= lat <= 90 and -180 <= lon <= 180
        ):
            return (lat, lon)
    except (pynmea2.ParseError, ValueError, TypeError, AttributeError):
        pass
    return None


def positive_float(text):
    value = float(text)
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return value


def non_negative_float(text):
    value = float(text)
    if not math.isfinite(value) or value < 0:
        raise argparse.ArgumentTypeError("must be a finite number, zero or greater")
    return value


def lat_lon(text):
    try:
        lat, lon = (float(part) for part in text.strip().split(","))
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected LAT,LON, got {text!r}") from None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        raise argparse.ArgumentTypeError(f"coordinates out of range: {text!r}")
    return (lat, lon)


def read_targets_file(path):
    with open(path) as f:
        lines = [line.strip() for line in f]
    return [lat_lon(line) for line in lines if line and not line.startswith("#")]


def parse_args():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--gps-port", default=GPS_PORT)
    parser.add_argument("--baud-rate", type=int, default=BAUD_RATE)
    parser.add_argument("--osc-host", default=OSC_HOST)
    parser.add_argument("--osc-port", type=int, default=OSC_PORT)
    parser.add_argument("--osc-path", default=OSC_PATH)
    parser.add_argument("--node", choices=tuple(PEERS), default=default_node(),
                        help="bike ID (default inferred from bikes1..bikes4 user/hostname)")
    parser.add_argument("--peer-port", type=int, default=PEER_PORT,
                        help="GPS peer UDP port; use the same port on all bikes")
    parser.add_argument("--listen-ip", default="0.0.0.0", help="local IPv4 peer-listener address")
    parser.add_argument("--peer", action="append", default=[], metavar="ID=IP",
                        help="override a bike IPv4 address (repeatable)")
    parser.add_argument("--no-peers", action="store_true", help="disable peer send/listen for standalone tests")
    parser.add_argument("--radius-feet", type=positive_float, default=75.0)
    parser.add_argument("--exit-margin-feet", type=non_negative_float, default=30.0)
    parser.add_argument("--gps-timeout", type=positive_float, default=GPS_TIMEOUT)
    parser.add_argument("--add-target", action="append", type=lat_lon, default=[],
                        metavar="LAT,LON", help="append a test target (repeatable)")
    parser.add_argument("--targets-file", metavar="PATH",
                        help="CSV of lat,lon per line, replaces the built-in list")
    parser.add_argument("--simulate", nargs="?", const="stdin", choices=("stdin", "walk"),
                        help="no serial port: read lat,lon lines from stdin, or walk through the first target")
    args = parser.parse_args()
    if args.baud_rate <= 0:
        parser.error("--baud-rate must be greater than zero")
    if not 1 <= args.osc_port <= 65535:
        parser.error("--osc-port must be between 1 and 65535")
    if not args.osc_path.startswith("/"):
        parser.error("--osc-path must start with /")
    if not 1 <= args.peer_port <= 65535 or args.peer_port == args.osc_port:
        parser.error("--peer-port must be 1..65535 and different from --osc-port")
    if not args.no_peers and args.node is None:
        parser.error("Cannot infer bike ID: pass --node 1..4, or --no-peers for standalone use")
    args.peers = dict(PEERS)
    try:
        ipaddress.IPv4Address(args.listen_ip)
        for item in args.peer:
            node, separator, ip = item.partition("=")
            if not separator or node not in PEERS:
                raise ValueError("--peer expects ID=IP, with ID 1..4")
            args.peers[node] = str(ipaddress.IPv4Address(ip))
    except ValueError as error:
        parser.error(str(error))
    try:
        args.targets = read_targets_file(args.targets_file) if args.targets_file else list(TARGETS)
    except (OSError, argparse.ArgumentTypeError) as error:
        parser.error(f"--targets-file: {error}")
    args.targets += args.add_target
    if not args.targets:
        parser.error("no targets")
    return args


def serial_positions(args):
    with serial.Serial(args.gps_port, args.baud_rate, timeout=0.5) as gps:
        print(f"GPS connected: {args.gps_port}, baud {args.baud_rate}", flush=True)
        while True:
            yield parse_position(gps.readline().decode("ascii", errors="replace").strip())


def stdin_positions():
    print("Simulating: type lat,lon per line", flush=True)
    while True:
        if not select.select([sys.stdin], [], [], 0.5)[0]:
            yield None
            continue
        line = sys.stdin.readline()
        if not line:
            return
        if line.strip():
            try:
                yield lat_lon(line)
            except argparse.ArgumentTypeError as error:
                print(error, flush=True)


def walk_positions(target):
    """East-west line through the target, 1 m per step."""
    lat, lon = target
    meters_per_degree = 111320 * math.cos(math.radians(lat))
    print(f"Simulating: walking through {lat:.6f}, {lon:.6f}", flush=True)
    for meters in range(-WALK_METERS, WALK_METERS + 1):
        yield (lat, lon + meters * WALK_STEP_METERS / meters_per_degree)
        time.sleep(WALK_STEP_SECONDS)


def read_gps(args, osc_client, positions, peer_relay=None):
    radius = args.radius_feet * FEET
    exit_radius = (args.radius_feet + args.exit_margin_feet) * FEET
    last_check = float("-inf")
    last_valid_fix = None
    last_zero = float("-inf")
    last_beat = float("-inf")
    zone = 0
    gps_unavailable = False

    def send_zone(value, now):
        nonlocal zone, last_beat
        entered = value == 1 and zone == 0
        if value != zone:
            print(f"{ZONE_PATH} {value}", flush=True)
        zone = value
        osc_client.send_message(ZONE_PATH, value)
        last_beat = now
        if entered and peer_relay is not None:
            peer_relay.entered()

    def send_zero(reason, now):
        nonlocal last_zero, gps_unavailable
        osc_client.send_message(args.osc_path, 0.0)
        last_zero = now
        if not gps_unavailable:
            print(f"{reason}; OSC proximity = 0.000", flush=True)
        gps_unavailable = True
        if zone:
            send_zone(0, now)

    try:
        send_zero("Waiting for a valid GPS fix", time.monotonic())
        print(
            f"OSC: {args.osc_host}:{args.osc_port} {args.osc_path} {ZONE_PATH}; "
            f"{len(args.targets)} targets, radius {radius:.2f} m ({args.radius_feet:g} ft), "
            f"exit {exit_radius:.2f} m\n",
            flush=True,
        )

        for position in positions:
            now = time.monotonic()
            if now - last_beat >= HEARTBEAT:
                send_zone(zone, now)
            if position is None:
                # Check silence, malformed input, and non-position sentences.
                stale = last_valid_fix is None or now - last_valid_fix >= args.gps_timeout
                if stale and now - last_zero >= ZERO_INTERVAL:
                    send_zero("No recent valid GPS fix", now)
                continue
            lat, lon = position
            if lat is None:
                last_valid_fix = None
                send_zero("GPS reports no valid fix", now)
                continue

            last_valid_fix = now
            # Always process the first recovered fix, even after a short dropout.
            if not gps_unavailable and now - last_check < UPDATE_INTERVAL:
                continue
            last_check = now
            gps_unavailable = False

            distances = [
                distance_meters(lat, lon, target_lat, target_lon)
                for target_lat, target_lon in args.targets
            ]
            nearest_index = min(range(len(distances)), key=distances.__getitem__)
            nearest_distance = distances[nearest_index]
            value = proximity_value(nearest_distance, radius)

            # ONE aggregate float, including 0 when every camera is outside.
            osc_client.send_message(args.osc_path, float(value))

            if not zone and nearest_distance <= radius:
                send_zone(1, now)
            elif zone and nearest_distance > exit_radius:
                send_zone(0, now)

            print(
                f"fix {lat:.6f},{lon:.6f} target {nearest_index + 1} "
                f"{nearest_distance:.1f} m {nearest_distance / FEET:.0f} ft "
                f"proximity {value:.3f} zone {zone}",
                flush=True,
            )
    finally:
        # Runs on Ctrl+C, a serial disconnect, and ordinary exceptions.
        # Avoid replacing an existing serial error with a shutdown send error.
        try:
            osc_client.send_message(args.osc_path, 0.0)
            osc_client.send_message(ZONE_PATH, 0)
            print("Sent final OSC proximity = 0.000, zone = 0", flush=True)
        except OSError as error:
            print(f"Could not send final OSC zero: {error}", flush=True)


def main():
    args = parse_args()
    if args.simulate == "walk":
        positions = walk_positions(args.targets[0])
    elif args.simulate == "stdin":
        positions = stdin_positions()
    else:
        positions = serial_positions(args)
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    peer_relay = None
    try:
        osc_client = SimpleUDPClient(args.osc_host, args.osc_port)
        if not args.no_peers:
            peer_relay = PeerZoneRelay(args.node, args.peers, args.peer_port, osc_client, args.listen_ip)
            peer_relay.start()
        read_gps(args, osc_client, positions, peer_relay)
    except KeyboardInterrupt:
        print("\nGPS program stopped.")
    except serial.SerialException as error:
        print(f"GPS serial error: {error}")
        return 1
    except OSError as error:
        print(f"GPS/OSC error: {error}")
        return 1
    finally:
        if peer_relay is not None:
            peer_relay.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
