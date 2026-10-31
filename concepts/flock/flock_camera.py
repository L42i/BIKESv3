#!/usr/bin/env python3
"""BIKES Flocking camera process: IMX500 detections -> presence OSC for SuperCollider.

Reuses the detector setup and tracker from ../camera/camera_osc.py. Sends one int
per address, 1 = present, 0 = absent, on every change and again every 2 s:

  /object/detected/person  1|0
  /object/detected/car     1|0

Only one process can open the IMX500, so stop camera_osc.py before starting this.
Exits cleanly if no IMX500 camera is attached.

Usage: python3 flock_camera.py --facing left [--stream-port 8000] [--send LAPTOP_IP:57120]
See README.md in this folder.
"""
import argparse
import json
import os
import signal
import sys
import time

from pythonosc.udp_client import SimpleUDPClient

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "camera"))
from camera_osc import (  # noqa: E402
    DEFAULT_HFOV, FRAME_H, FRAME_W, LABELS_JSON, MODEL,
    DebugStream, Tracker, parse_destination, resolve_facing,
)

HEARTBEAT = 2.0
APPROACH_GROWTH = 0.25
# Tracker only confirms tracks in these categories; the class map does the filtering
TRACKER_CATEGORIES = "person,vehicle,bike,animal,other"


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--facing", default="left",
                    help="camera direction on the bike: front/left/right/back or degrees (default left)")
    ap.add_argument("--rotate180", action="store_true", help="camera is mounted upside down")
    ap.add_argument("--osc-host", default="127.0.0.1")
    ap.add_argument("--osc-port", type=int, default=57120)
    ap.add_argument("--send", action="append", default=[], metavar="HOST:PORT",
                    help="also send every message here, e.g. a laptop 10.10.10.50:57120 (repeatable)")
    ap.add_argument("--class-map", default="person:person,car:car,truck:car,bus:car,motorcycle:car",
                    help="detector label -> address under /object/detected/")
    ap.add_argument("--threshold", type=float, default=0.55, help="minimum detection score")
    ap.add_argument("--confirm-hits", type=int, default=3, help="detections needed to confirm an object")
    ap.add_argument("--lost-after", type=float, default=0.6, help="seconds unseen before a track ends")
    ap.add_argument("--release", type=float, default=1.5, help="seconds with no objects before sending 0")
    ap.add_argument("--stream-port", type=int, default=0, help="serve an annotated MJPEG debug stream (0 = off)")
    ap.add_argument("--verbose", action="store_true", help="print the tracker's events")
    return ap.parse_args()


def parse_class_map(value):
    pairs = [item.split(":") for item in value.split(",") if item]
    if not pairs or any(len(p) != 2 or not p[0] or not p[1] for p in pairs):
        sys.exit(f"--class-map expects label:address,label:address, got {value!r}")
    return dict(pairs)


class Presence:
    """Debounced 1/0 state per address: up at once, down after `release` seconds empty."""

    def __init__(self, addresses, release, send):
        self.state = {a: 0 for a in addresses}
        self.last_seen = {a: 0.0 for a in addresses}
        self.release = release
        self.send = send
        self.next_beat = 0.0

    def update(self, counts, now):
        for a, value in self.state.items():
            if counts.get(a, 0) >= 1:
                self.last_seen[a] = now
                if not value:
                    self.change(a, 1)
            elif value and now - self.last_seen[a] >= self.release:
                self.change(a, 0)
        if now >= self.next_beat:
            self.next_beat = now + HEARTBEAT
            for a, value in self.state.items():
                self.send(a, value)

    def change(self, address, value):
        self.state[address] = value
        print(f"{time.strftime('%H:%M:%S')} /object/detected/{address} {value}", flush=True)
        self.send(address, value)

    def all_off(self):
        for a in self.state:
            self.state[a] = 0
            self.send(a, 0)


def main():
    args = parse_args()
    args.facing_deg = resolve_facing(args.facing)
    args.hfov = DEFAULT_HFOV
    args.approach_growth = APPROACH_GROWTH
    args.categories = TRACKER_CATEGORIES
    class_map = parse_class_map(args.class_map)

    from picamera2 import Picamera2
    cams = Picamera2.global_camera_info()
    if not any("imx500" in c.get("Model", "").lower() for c in cams):
        print("[flock camera] no IMX500 camera found, nothing to do", flush=True)
        return 0

    from picamera2.devices import IMX500

    with open(LABELS_JSON) as f:
        labels = json.load(f)["imx500_object_detection"]["classes"]

    destinations = [(args.osc_host, args.osc_port)] + [parse_destination(d) for d in args.send]
    clients = [SimpleUDPClient(host, port) for host, port in destinations]

    def send(address, value):
        for client in clients:
            try:
                client.send_message(f"/object/detected/{address}", int(value))
            except OSError:
                pass  # a laptop that left the network must not stop the bike's own sound

    def emit(path, *values):
        if args.verbose:
            print(path, *values, flush=True)

    tracker = Tracker(args, emit)
    presence = Presence(sorted(set(class_map.values())), args.release, send)
    stream = DebugStream(args.stream_port) if args.stream_port else None

    # IMX500 must be created before Picamera2 so the network firmware gets loaded
    imx500 = IMX500(MODEL)
    picam2 = Picamera2(imx500.camera_num)
    config = picam2.create_preview_configuration(
        main={"size": (FRAME_W, FRAME_H), "format": "RGB888"}, controls={"FrameRate": 30}, buffer_count=6)
    picam2.start(config)
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    print(f"[flock camera] facing {args.facing} ({args.facing_deg:+.0f} deg), "
          f"sending OSC to {', '.join(f'{h}:{p}' for h, p in destinations)}"
          + (f", debug stream on :{args.stream_port}" if stream else ""), flush=True)

    try:
        while True:
            if stream:
                request = picam2.capture_request()
                try:
                    metadata = request.get_metadata()
                    frame = request.make_array("main")
                finally:
                    request.release()
            else:
                metadata = picam2.capture_metadata()

            now = time.monotonic()
            outputs = imx500.get_outputs(metadata, add_batch=True)
            detections = []
            if outputs is not None:
                boxes, scores, classes = outputs[0][0], outputs[1][0], outputs[2][0]
                for box, score, cls in zip(boxes, scores, classes):
                    if score < args.threshold:
                        continue
                    cls = int(cls)
                    label = labels[cls] if cls < len(labels) else f"class{cls}"
                    if label == "-":
                        continue
                    box = tuple(float(v) for v in imx500.convert_inference_coords(box, metadata, picam2))
                    detections.append((label, float(score), box))
            tracker.update(detections, now)

            counts = {}
            for t in tracker.tracks:
                if t.confirmed and t.label in class_map:
                    counts[class_map[t.label]] = counts.get(class_map[t.label], 0) + 1
            presence.update(counts, now)

            if stream:
                stream.publish(frame, tracker.tracks, args.rotate180)
    except KeyboardInterrupt:
        pass
    finally:
        presence.all_off()
        picam2.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
