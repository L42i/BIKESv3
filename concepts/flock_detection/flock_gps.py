
"""BIKES GPS camera proximity -> flock_detection.scd on the same machine.

Install: python -m pip install pyserial pynmea2 python-osc
Run on Windows: python flock_gps.py
Run on a Pi: python3 flock_gps.py --gps-port /dev/ttyUSB0

Start the SuperCollider file first and wait for "Flock audio ready".
Defaults: COM3, 4800 baud, 75-foot radius, /flock/proximity -> 127.0.0.1:57120.
The OSC payload is ONE float, with no bike ID or target ID. When several cameras
are nearby, send the highest proximity (the nearest camera) once per update.
0 means no camera in range; 1 means at a camera's mapped coordinates.
0.5 corresponds to half the detection radius: 37.5 feet / 11.43 meters.

GPS fixes determine the actual update rate. UPDATE_INTERVAL is only a throttle;
it does not make a 1 Hz GPS produce 50 positions per second.
Invalid/no-fix GGA sends 0 immediately. Missing valid fixes for 5 seconds also
sends 0, repeated every 0.5 seconds until valid fixes resume. Shutdown sends 0.
The process must remain running for the stale-fix safeguard to work.
"""

import argparse
import math
import time

import pynmea2
import serial
from pythonosc.udp_client import SimpleUDPClient

GPS_PORT = "/dev/ttyACM0"
BAUD_RATE = 4800
UPDATE_INTERVAL = 0.02
RADIUS_METERS = 75 * 0.3048
OSC_HOST = "127.0.0.1"
OSC_PORT = 57120
OSC_PATH = "/flock/proximity"
GPS_TIMEOUT = 5.0
ZERO_INTERVAL = 0.5

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


def proximity_value(distance, radius=RADIUS_METERS):
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


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gps-port", default=GPS_PORT)
    parser.add_argument("--baud-rate", type=int, default=BAUD_RATE)
    parser.add_argument("--osc-host", default=OSC_HOST)
    parser.add_argument("--osc-port", type=int, default=OSC_PORT)
    parser.add_argument("--osc-path", default=OSC_PATH)
    parser.add_argument("--radius-feet", type=positive_float, default=75.0)
    parser.add_argument("--gps-timeout", type=positive_float, default=GPS_TIMEOUT)
    args = parser.parse_args()
    if args.baud_rate <= 0:
        parser.error("--baud-rate must be greater than zero")
    if not 1 <= args.osc_port <= 65535:
        parser.error("--osc-port must be between 1 and 65535")
    if not args.osc_path.startswith("/"):
        parser.error("--osc-path must start with /")
    return args


def read_gps(args, osc_client):
    radius = args.radius_feet * 0.3048
    last_check = float("-inf")
    last_valid_fix = None
    last_zero = float("-inf")
    targets_in_range = set()
    gps_unavailable = False

    def send_zero(reason, now):
        nonlocal last_zero, gps_unavailable
        osc_client.send_message(args.osc_path, 0.0)
        last_zero = now
        if not gps_unavailable:
            print(f"{reason}; OSC proximity = 0.000", flush=True)
        gps_unavailable = True
        targets_in_range.clear()

    try:
        send_zero("Waiting for a valid GPS fix", time.monotonic())
        with serial.Serial(args.gps_port, args.baud_rate, timeout=0.5) as gps:
            print(f"GPS connected: {args.gps_port}, baud {args.baud_rate}")
            print(
                f"OSC: {args.osc_host}:{args.osc_port} {args.osc_path}; "
                f"radius {radius:.2f} m ({args.radius_feet:g} ft)\n",
                flush=True,
            )

            while True:
                line = gps.readline().decode("ascii", errors="replace").strip()
                now = time.monotonic()
                position = parse_position(line)
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
                    for target_lat, target_lon in TARGETS
                ]
                nearest_index = min(range(len(distances)), key=distances.__getitem__)
                nearest_distance = distances[nearest_index]
                value = proximity_value(nearest_distance, radius)

                # ONE aggregate float, including 0 when every camera is outside.
                # This matches flock_detection.scd's default valueIndex: 1.
                osc_client.send_message(args.osc_path, float(value))

                print(f"Current location: {lat:.6f}, {lon:.6f}")
                currently_nearby = set()
                for i, distance in enumerate(distances, start=1):
                    if distance <= radius:
                        currently_nearby.add(i)
                        if i not in targets_in_range:
                            print(f"Entered range of Target {i}!")
                        print(
                            f"Target {i}: {distance:.2f} m "
                            f"({distance / 0.3048:.1f} ft), "
                            f"proximity = {proximity_value(distance, radius):.3f}"
                        )
                for i in sorted(targets_in_range - currently_nearby):
                    print(f"Left range of Target {i}.")
                targets_in_range = currently_nearby
                print(
                    f"OSC proximity = {value:.3f}; nearest Target {nearest_index + 1} "
                    f"at {nearest_distance:.2f} m\n",
                    flush=True,
                )
    finally:
        # Runs on Ctrl+C, a serial disconnect, and ordinary exceptions.
        # Avoid replacing an existing serial error with a shutdown send error.
        try:
            osc_client.send_message(args.osc_path, 0.0)
            print("Sent final OSC proximity = 0.000", flush=True)
        except OSError as error:
            print(f"Could not send final OSC zero: {error}", flush=True)


def main():
    args = parse_args()
    try:
        osc_client = SimpleUDPClient(args.osc_host, args.osc_port)
        read_gps(args, osc_client)
    except KeyboardInterrupt:
        print("\nGPS program stopped.")
    except serial.SerialException as error:
        print(f"GPS serial error: {error}")
        return 1
    except OSError as error:
        print(f"GPS/OSC error: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
