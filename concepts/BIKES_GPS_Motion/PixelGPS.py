#!/usr/bin/env python3
"""BIKES GPS motion detector and peer OSC coordinator (no graphical UI).

Dependencies: pyserial, python-osc. Run --help for thresholds and endpoints.
Peer OSC messages only cache a candidate; local GPS motion is required to play.
"""
from __future__ import annotations

import argparse
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
import getpass
import logging
import math
import queue
import random
import signal
import threading
import time
import uuid

MOTIONS = ("accelerate", "decelerate", "turn_left", "turn_right")
PEERS = {"1": "10.10.10.11", "2": "10.10.10.12",
         "3": "10.10.10.13", "4": "10.10.10.14"}
LOG = logging.getLogger("PixelGPS")


@dataclass(frozen=True)
class GPSFix:
    timestamp: float                 # UTC from RMC, not serial arrival time
    speed: float                     # metres / second
    course: float | None             # degrees clockwise from true north


def parse_nmea(line: str):
    """Checksum-verified RMC/GGA parser. Other sentence types are ignored.

    Returns ('fix', GPSFix), ('quality', (quality, satellites, hdop)),
    ('invalid', None), or None. Both GP and GN talkers are accepted.
    """
    line = line.strip()
    if not line.startswith("$") or "*" not in line:
        return None
    body, supplied = line[1:].rsplit("*", 1)
    try:
        checksum = 0
        for character in body:
            checksum ^= ord(character)
        if len(supplied) != 2 or checksum != int(supplied, 16):
            return None
        fields = body.split(",")
        kind = fields[0][-3:]
        if kind == "GGA":
            quality = int(fields[6] or "0")
            satellites = int(fields[7] or "0")
            hdop = float(fields[8]) if fields[8] else math.inf
            return "quality", (quality, satellites, hdop)
        if kind != "RMC":
            return None
        if fields[2] != "A" or (len(fields) > 12 and fields[12] == "N"):
            return "invalid", None
        # A valid velocity fix must have a date, UTC time and speed.
        raw_time, raw_date = fields[1], fields[9]
        if len(raw_date) != 6 or len(raw_time) < 6 or not fields[7]:
            return "invalid", None
        year = int(raw_date[4:6])
        year += 2000 if year < 80 else 1900
        seconds = float(raw_time[4:])
        whole_seconds = int(seconds)
        stamp = datetime(year, int(raw_date[2:4]), int(raw_date[:2]),
                         int(raw_time[:2]), int(raw_time[2:4]), whole_seconds,
                         int((seconds - whole_seconds) * 1_000_000),
                         tzinfo=timezone.utc).timestamp()
        speed = float(fields[7]) * (1852.0 / 3600.0)
        course = float(fields[8]) if fields[8] else None
        if not math.isfinite(speed) or not 0 <= speed <= 35:
            return "invalid", None
        if course is not None and (not math.isfinite(course) or not 0 <= course <= 360):
            return "invalid", None
        return "fix", GPSFix(stamp, speed, None if course is None else course % 360)
    except (ValueError, IndexError, OverflowError):
        return None


def slope(points) -> float:
    if len(points) < 2:
        return 0.0
    # Offset large UTC values before regression to preserve precision.
    origin = points[0][0]
    xs = [p[0] - origin for p in points]
    ys = [p[1] for p in points]
    mean_x, mean_y = sum(xs) / len(xs), sum(ys) / len(ys)
    denominator = sum((x - mean_x) ** 2 for x in xs)
    return (sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
            / denominator) if denominator > 0 else 0.0


class MotionDetector:
    def __init__(self, args):
        self.args = args
        self.last_trigger = {kind: -math.inf for kind in MOTIONS}
        self.reset()

    def reset(self):
        self.speeds, self.headings = deque(), deque()
        self.last_fix = None
        self.filtered_speed = None
        self.previous_course = None
        self.unwrapped_course = 0.0
        self.counts = {kind: 0 for kind in MOTIONS}
        self.latched = {kind: False for kind in MOTIONS}
        self.metrics = {"speed": 0.0, "acceleration": 0.0, "turn_rate": 0.0}

    def update(self, fix: GPSFix, now: float) -> list[str]:
        if self.last_fix is not None:
            dt = fix.timestamp - self.last_fix.timestamp
            if dt <= 0:
                return []             # duplicated or out-of-order RMC
            if dt > self.args.gps_timeout:
                self.reset()          # never differentiate across loss of fix
        dt = 0 if self.last_fix is None else fix.timestamp - self.last_fix.timestamp
        self.last_fix = fix
        alpha = 1.0 if self.filtered_speed is None else 1 - math.exp(-dt / self.args.smoothing)
        self.filtered_speed = (fix.speed if self.filtered_speed is None else
                               self.filtered_speed + alpha * (fix.speed - self.filtered_speed))
        self.speeds.append((fix.timestamp, self.filtered_speed))
        while self.speeds and fix.timestamp - self.speeds[0][0] > self.args.window:
            self.speeds.popleft()
        acceleration = (slope(self.speeds) if len(self.speeds) >= 2 and
                        self.speeds[-1][0] - self.speeds[0][0] >= self.args.min_span else 0.0)

        # Course-over-ground is unreliable while stopped / walking slowly.
        if fix.course is None or fix.speed < self.args.min_turn_speed:
            self.headings.clear()
            self.previous_course = None
            self.unwrapped_course = 0.0
        else:
            if self.previous_course is not None:
                delta = (fix.course - self.previous_course + 180) % 360 - 180
                self.unwrapped_course += delta
            self.previous_course = fix.course
            self.headings.append((fix.timestamp, self.unwrapped_course))
            while self.headings and fix.timestamp - self.headings[0][0] > self.args.window:
                self.headings.popleft()
        enough_heading = (len(self.headings) >= 2 and
                          self.headings[-1][0] - self.headings[0][0] >= self.args.min_span)
        turn_rate = slope(self.headings) if enough_heading else 0.0
        turn_angle = (self.headings[-1][1] - self.headings[0][1]) if enough_heading else 0.0
        self.metrics = {"speed": self.filtered_speed, "acceleration": acceleration,
                        "turn_rate": turn_rate}
        scores = {
            "accelerate": max(0.0, acceleration) / self.args.accel_threshold,
            "decelerate": max(0.0, -acceleration) / self.args.decel_threshold,
            "turn_right": min(max(0.0, turn_rate) / self.args.turn_rate,
                              max(0.0, turn_angle) / self.args.turn_angle),
            "turn_left": min(max(0.0, -turn_rate) / self.args.turn_rate,
                             max(0.0, -turn_angle) / self.args.turn_angle),
        }
        ready = []
        for kind, score in scores.items():
            if score < 0.7:
                self.latched[kind] = False  # rearm only after leaving the motion
            self.counts[kind] = self.counts[kind] + 1 if score >= 1 else 0
            if (self.counts[kind] >= self.args.confirm_samples and not self.latched[kind]
                    and now - self.last_trigger[kind] >= self.args.cooldown):
                ready.append(kind)
        if not ready:
            return []
        # One audio switch per GPS fix; choose the strongest normalized motion.
        chosen = max(ready, key=lambda kind: scores[kind])
        self.latched[chosen] = True
        self.last_trigger[chosen] = now
        return [chosen]


@dataclass(frozen=True)
class MotionEvent:
    event_id: str
    source: str
    kind: str
    number: int
    created: float

    def packet(self):
        # OSC's default float is float32: send Unix time as text, not float32.
        return [self.event_id, self.source, self.kind, self.number, f"{self.created:.6f}"]


class RhythmRateController:
    """Smooth signed acceleration into a bounded rhythmic playback rate.

    Attack/recovery times describe approximately 95% convergence. Invalid or
    expired GPS input returns gently to default; it never freezes a changed rate.
    """
    def __init__(self, default_rate=1.0, min_rate=0.6, max_rate=1.5,
                 gain=0.4, attack_time=0.35, return_time=4.0, input_timeout=4.0):
        self.default_rate, self.min_rate, self.max_rate = default_rate, min_rate, max_rate
        self.gain, self.attack_time, self.return_time = gain, attack_time, return_time
        self.input_timeout = input_timeout
        self.current_rate = default_rate
        self.last_update = None
        self.neutral()

    def neutral(self):
        self.acceleration, self.last_observation, self.active = 0.0, None, False

    def observe(self, acceleration, now, active=True):
        if not math.isfinite(acceleration):
            self.neutral()
            return
        self.acceleration, self.last_observation, self.active = acceleration, now, active

    def advance(self, now):
        dt = 0.0 if self.last_update is None else max(0.0, now - self.last_update)
        self.last_update = now
        fresh = self.last_observation is not None and now - self.last_observation <= self.input_timeout
        if fresh and self.active:
            target = min(self.max_rate, max(self.min_rate,
                         self.default_rate + self.gain * self.acceleration))
            duration = self.attack_time
        else:
            target, duration = self.default_rate, self.return_time
        alpha = 1.0 - math.exp(-math.log(20.0) * dt / duration)
        self.current_rate += alpha * (target - self.current_rate)
        self.current_rate = min(self.max_rate, max(self.min_rate, self.current_rate))
        return self.current_rate


def demo_speed(elapsed):
    """A 32-second cycle: accelerate, cruise, decelerate, cruise (m/s)."""
    position = elapsed % 32.0
    if position < 8:
        return 3.0 + position
    if position < 16:
        return 11.0
    if position < 24:
        return 11.0 - (position - 16)
    return 3.0


class MotionCoordinator:
    """Deterministic first-event selection within a finite matching window.

    All state is accessed from the main thread. The OSC thread only enqueues.
    Cached remote events alone NEVER create a pending local playback.
    """
    def __init__(self, host, sample_count=4, match_window=8.0, settle_time=0.6):
        self.host, self.sample_count = host, sample_count
        self.match_window, self.settle_time = match_window, settle_time
        self.events = {}
        self.pending = {}

    def prune(self, wall_now):
        self.events = {key: event for key, event in self.events.items()
                       if -1 <= wall_now - event.created <= self.match_window}

    def remember(self, event, wall_now):
        self.prune(wall_now)
        if (event.kind not in MOTIONS or event.source not in PEERS or
                not 0 <= event.number < self.sample_count or
                not math.isfinite(event.created) or
                not -1 <= wall_now - event.created <= self.match_window or
                not 1 <= len(event.event_id) <= 80):
            return False
        if event.event_id in self.events:
            return False
        if len(self.events) >= 256:
            return False
        self.events[event.event_id] = event
        return True

    def winner(self, kind, wall_now):
        self.prune(wall_now)
        candidates = [event for event in self.events.values() if event.kind == kind]
        return min(candidates, key=lambda e: (e.created, e.source, e.event_id)) if candidates else None

    def local(self, kind, wall_now, mono_now, metrics):
        previous = self.winner(kind, wall_now)
        number = previous.number if previous else random.randrange(self.sample_count)
        event = MotionEvent(uuid.uuid4().hex, self.host, kind, number, wall_now)
        self.remember(event, wall_now)
        self.pending[kind] = (mono_now + self.settle_time, event, dict(metrics))
        return event

    def due(self, wall_now, mono_now):
        decisions = []
        for kind, (deadline, local_event, metrics) in list(self.pending.items()):
            if mono_now >= deadline:
                event = self.winner(kind, wall_now) or local_event
                decisions.append((event, metrics, local_event.event_id))
                del self.pending[kind]
        return decisions


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("soundscape", nargs="?", default="marine")
    parser.add_argument("--host", choices=tuple(PEERS),
                        default=getpass.getuser().removeprefix("bikes"))
    parser.add_argument("--gps-port", default="/dev/ttyUSB0")
    parser.add_argument("--baud-rate", type=int, default=9600)
    parser.add_argument("--sc-ip", default="127.0.0.1")
    parser.add_argument("--sc-port", type=int, default=57120)
    parser.add_argument("--listen-ip", default="0.0.0.0")
    parser.add_argument("--peer-port", type=int, default=57121)
    parser.add_argument("--peer", action="append", default=[], metavar="ID=IP",
                        help="Override a peer IP; can be repeated")
    parser.add_argument("--sample-count", type=int, default=4)
    parser.add_argument("--window", type=float, default=2.5)
    parser.add_argument("--min-span", type=float, default=1.0)
    parser.add_argument("--smoothing", type=float, default=0.8)
    parser.add_argument("--accel-threshold", type=float, default=0.4)
    parser.add_argument("--decel-threshold", type=float, default=0.4)
    parser.add_argument("--turn-rate", type=float, default=10.0)
    parser.add_argument("--turn-angle", type=float, default=25.0)
    parser.add_argument("--min-turn-speed", type=float, default=0.5)
    parser.add_argument("--confirm-samples", type=int, default=2)
    parser.add_argument("--cooldown", type=float, default=5.0)
    parser.add_argument("--match-window", type=float, default=8.0)
    parser.add_argument("--settle-time", type=float, default=0.6)
    parser.add_argument("--gps-timeout", type=float, default=4.0)
    parser.add_argument("--max-hdop", type=float, default=4.0)
    parser.add_argument("--min-satellites", type=int, default=4)
    parser.add_argument("--default-rate", type=float, default=1.0)
    parser.add_argument("--min-rate", type=float, default=0.6)
    parser.add_argument("--max-rate", type=float, default=1.5)
    parser.add_argument("--rate-gain", type=float, default=0.2,
                        help="Playback-rate change per m/s2 of confirmed acceleration")
    parser.add_argument("--rate-attack", type=float, default=3.0)
    parser.add_argument("--rate-return", type=float, default=4.0,
                        help="Seconds to recover approximately 95 percent toward default")
    parser.add_argument("--rate-hz", type=float, default=10.0)
    parser.add_argument("--demo", action="store_true",
                        help="Use simulated acceleration/deceleration; do not open a GPS port")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if args.host not in PEERS:
        parser.error("Run as bikes1..bikes4 or explicitly pass --host 1..4")
    positive = ("baud_rate", "sample_count", "window", "min_span", "smoothing",
                "accel_threshold", "decel_threshold", "turn_rate", "turn_angle",
                "min_turn_speed", "confirm_samples", "cooldown", "match_window",
                "settle_time", "gps_timeout", "max_hdop", "min_satellites",
                "default_rate", "min_rate", "max_rate", "rate_gain",
                "rate_attack", "rate_return", "rate_hz")
    if any(not math.isfinite(getattr(args, key)) or getattr(args, key) <= 0 for key in positive):
        parser.error("All thresholds, counts and time intervals must be positive and finite")
    if args.window < args.min_span or args.match_window <= args.settle_time:
        parser.error("window must be >= min-span; match-window must exceed settle-time")
    if not (1 <= args.sc_port <= 65535 and 1 <= args.peer_port <= 65535):
        parser.error("OSC ports must be between 1 and 65535")
    if not (0.1 <= args.min_rate <= args.default_rate <= args.max_rate <= 4.0):
        parser.error("Require 0.1 <= min-rate <= default-rate <= max-rate <= 4.0")
    if args.rate_hz > 50:
        parser.error("rate-hz must be <= 50")
    return args


def main():
    args = arguments()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    try:
        import serial
        from pythonosc import dispatcher, osc_server, udp_client
    except ImportError as error:
        raise SystemExit("Install dependencies: python3 -m pip install pyserial python-osc") from error
    peers = dict(PEERS)
    for item in args.peer:
        node, separator, address = item.partition("=")
        if node not in peers or not separator or not address:
            raise SystemExit("--peer must be ID=IP, with ID from 1 to 4")
        peers[node] = address
    host = args.host
    peer = {node: udp_client.SimpleUDPClient(address, args.peer_port)
            for node, address in peers.items() if node != host}
    ip, port = args.sc_ip, args.sc_port
    osc_client = udp_client.SimpleUDPClient(ip, port)
    incoming = queue.Queue(maxsize=256)
    stop = threading.Event()
    detector = MotionDetector(args)
    coordinator = MotionCoordinator(host, args.sample_count, args.match_window, args.settle_time)
    rhythm = RhythmRateController(args.default_rate, args.min_rate, args.max_rate,
                                 args.rate_gain, args.rate_attack, args.rate_return, args.gps_timeout)
    outbox = []

    def receive(address, *values):
        if len(values) != 5:
            return
        try:
            if isinstance(values[3], bool) or not isinstance(values[3], int):
                return
            event = MotionEvent(str(values[0]), str(values[1]), str(values[2]),
                                values[3], float(values[4]))
            if event.source == host:
                return
            incoming.put_nowait(event)
        except (ValueError, TypeError, queue.Full):
            return

    routes = dispatcher.Dispatcher()
    routes.map("/motionShare", receive)
    server = osc_server.BlockingOSCUDPServer((args.listen_ip, args.peer_port), routes)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda *_: stop.set())
    connection = None
    retry_at, last_fix_at = 0.0, None
    quality, quality_at = None, -math.inf
    raw_buffer = bytearray()
    last_rate_sent, last_rate_log = -math.inf, -math.inf
    demo_started, next_demo_fix = time.monotonic(), 0.0

    def feed_fix(fix, now):
        nonlocal last_fix_at
        if detector.last_fix is not None and fix.timestamp <= detector.last_fix.timestamp:
            return
        last_fix_at = now
        kinds = detector.update(fix, now)
        changing_speed = any(detector.counts[kind] >= args.confirm_samples
                             for kind in ("accelerate", "decelerate"))
        rhythm.observe(detector.metrics["acceleration"], now, active=changing_speed)
        for kind in kinds:
            event = coordinator.local(kind, time.time(), now, detector.metrics)
            outbox.extend((now + delay, event) for delay in (0.0, 0.15, 0.35))
            LOG.info("Detected %s; announcing %s.wav", kind, event.number)
        LOG.debug("speed=%.2f m/s acceleration=%.2f m/s2 turn=%.1f deg/s",
                  detector.metrics["speed"], detector.metrics["acceleration"],
                  detector.metrics["turn_rate"])

    LOG.info("Bike %s theme=%s GPS=%s baud=%s peer OSC=%s local SC=%s:%s",
             host, args.soundscape, args.gps_port, args.baud_rate, args.peer_port, ip, port)
    if args.demo:
        LOG.warning("DEMO: simulated GPS; no physical sensor is read. Cycle length: 32 seconds")
    try:
        while not stop.is_set():
            now, wall_now = time.monotonic(), time.time()
            rate = rhythm.advance(now)
            if now - last_rate_sent >= 1.0 / args.rate_hz:
                osc_client.send_message("/rhythmRate", [rate, args.default_rate, args.rate_return, 0.12])
                last_rate_sent = now
            if now - last_rate_log >= 1.0:
                LOG.debug("rhythm rate=%.3fx", rate)
                last_rate_log = now
            while not incoming.empty():
                event = incoming.get_nowait()
                if coordinator.remember(event, wall_now):
                    LOG.info("Cached %s from bike %s -> %s.wav (no local playback)",
                             event.kind, event.source, event.number)
            for deadline, event in list(outbox):
                if now >= deadline:
                    for client in peer.values():
                        try:
                            client.send_message("/motionShare", event.packet())
                        except OSError as error:
                            LOG.warning("Peer OSC send failed: %s", error)
                    outbox.remove((deadline, event))
            for event, metrics, trigger_id in coordinator.due(wall_now, now):
                osc_client.send_message("/motion", [event.kind, event.number, trigger_id,
                                        event.source, metrics["acceleration"], metrics["turn_rate"]])
                LOG.info("PLAY %s/%s.wav chosen by bike %s, acceleration=%.2f turn=%.1f",
                         event.kind, event.number, event.source,
                         metrics["acceleration"], metrics["turn_rate"])
            if last_fix_at is not None and now - last_fix_at > args.gps_timeout:
                detector.reset()
                rhythm.neutral()
                last_fix_at = None
                LOG.warning("GPS fix timed out; motion history cleared")
            if args.demo:
                if now >= next_demo_fix:
                    feed_fix(GPSFix(wall_now, demo_speed(now - demo_started), 90.0), now)
                    next_demo_fix = now + 0.5
                stop.wait(0.02)
                continue
            if connection is None:
                if now < retry_at:
                    stop.wait(0.05)
                    continue
                try:
                    options = {"exclusive": True} if args.gps_port.startswith("/") else {}
                    connection = serial.Serial(args.gps_port, args.baud_rate, timeout=0.05, **options)
                    connection.reset_input_buffer()
                    raw_buffer.clear()
                    quality, quality_at = None, -math.inf
                    detector.reset()
                    LOG.info("GPS connected; waiting for valid RMC sentences")
                except (serial.SerialException, OSError) as error:
                    LOG.warning("GPS unavailable: %s; retry in 3 seconds", error)
                    retry_at = now + 3
                    continue
            try:
                raw_buffer.extend(connection.read(min(connection.in_waiting or 1, 4096)))
            except (serial.SerialException, OSError) as error:
                LOG.warning("GPS disconnected: %s", error)
                connection.close()
                connection = None
                detector.reset()
                rhythm.neutral()
                last_fix_at = None
                retry_at = time.monotonic() + 3
                continue
            while b"\n" in raw_buffer:
                line, _, remaining = raw_buffer.partition(b"\n")
                raw_buffer = bytearray(remaining)
                parsed = parse_nmea(line.decode("ascii", errors="replace"))
                if parsed is None:
                    continue
                category, value = parsed
                now = time.monotonic()
                if category == "quality":
                    quality, quality_at = value, now
                    continue
                quality_bad = (quality is not None and now - quality_at <= args.gps_timeout and
                               (quality[0] == 0 or quality[1] < args.min_satellites or
                                quality[2] > args.max_hdop))
                if category == "invalid" or quality_bad:
                    detector.reset()
                    rhythm.neutral()
                    last_fix_at = None
                    continue
                feed_fix(value, now)
            if len(raw_buffer) > 4096:
                raw_buffer.clear()
                LOG.warning("Discarded overlong/incomplete serial input")
    finally:
        # Request a gentle return if Python is stopped while SC keeps playing.
        try:
            osc_client.send_message("/rhythmRate", [args.default_rate, args.default_rate,
                                    args.rate_return, args.rate_return])
        except OSError:
            pass
        if connection is not None:
            connection.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        LOG.info("Stopped")


if __name__ == "__main__":
    main()
