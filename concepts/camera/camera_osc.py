#!/usr/bin/env python3
"""BIKES camera service: IMX500 on-sensor object detection -> OSC for SuperCollider.

Runs the same on every bike. If no IMX500 camera is attached it prints a note and
exits cleanly, so concept playbooks can start it everywhere.

Detections are tracked over time and turned into a few musical signals, sent to
the local sclang (127.0.0.1:57120). Every message starts with this bike's node id:

  /cam/state    node people vehicles bikes animals total passRate   (state-hz, smoothed)
  /cam/enter    node id label category azimuth closeness            (object confirmed in view)
  /cam/exit     node id label category duration                     (object gone)
  /cam/approach node id label category azimuth closeness growth     (object getting bigger fast)

azimuth: degrees relative to the bike, 0 = straight ahead, -90 = left, +90 = right, 180 = behind.
closeness: sqrt of the box's share of the frame (0..1), a rough "how close".
passRate: confirmed objects entering view per minute (~20 s smoothing).

Usage: python3 camera_osc.py --facing left [--stream-port 8000]
"""
import argparse
import getpass
import json
import math
import re
import signal
import sys
import threading
import time
from collections import deque

from pythonosc.udp_client import SimpleUDPClient

MODEL = "/usr/share/imx500-models/imx500_network_ssd_mobilenetv2_fpnlite_320x320_pp.rpk"
LABELS_JSON = "/usr/share/rpi-camera-assets/imx500_mobilenet_ssd.json"
FACINGS = {"front": 0.0, "right": 90.0, "back": 180.0, "left": -90.0}
# Raspberry Pi AI Camera horizontal field of view
DEFAULT_HFOV = 66.3
FRAME_W, FRAME_H = 640, 480

CATEGORIES = {
    "person": "person",
    "bicycle": "bike",
    **{k: "vehicle" for k in ("car", "motorcycle", "bus", "truck", "train", "boat", "airplane")},
    **{k: "animal" for k in ("bird", "cat", "dog", "horse", "sheep", "cow",
                             "elephant", "bear", "zebra", "giraffe")},
}
STATE_CATEGORIES = ("person", "vehicle", "bike", "animal")


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--facing", default="left",
                    help="camera direction on the bike: front/left/right/back or degrees (default left)")
    ap.add_argument("--rotate180", action="store_true", help="camera is mounted upside down")
    ap.add_argument("--hfov", type=float, default=DEFAULT_HFOV, help="horizontal field of view, degrees")
    ap.add_argument("--node", help="node id sent with every message (default: digit from user name bikesN)")
    ap.add_argument("--osc-host", default="127.0.0.1")
    ap.add_argument("--osc-port", type=int, default=57120)
    ap.add_argument("--threshold", type=float, default=0.55, help="minimum detection score")
    ap.add_argument("--categories", default=",".join(STATE_CATEGORIES),
                    help="categories that generate events (person,vehicle,bike,animal,other)")
    ap.add_argument("--confirm-hits", type=int, default=3, help="detections needed before /cam/enter")
    ap.add_argument("--lost-after", type=float, default=0.6, help="seconds unseen before /cam/exit")
    ap.add_argument("--approach-growth", type=float, default=0.25,
                    help="size increase per second that counts as approaching")
    ap.add_argument("--state-hz", type=float, default=10.0)
    ap.add_argument("--stream-port", type=int, default=0, help="serve an annotated MJPEG debug stream (0 = off)")
    ap.add_argument("--verbose", action="store_true", help="print every event")
    return ap.parse_args()


def resolve_facing(value):
    if value.lower() in FACINGS:
        return FACINGS[value.lower()]
    try:
        return float(value)
    except ValueError:
        sys.exit(f"--facing must be one of {', '.join(FACINGS)} or a number of degrees, got {value!r}")


def resolve_node(value):
    if value:
        return str(value)
    m = re.search(r"(\d+)$", getpass.getuser())
    return m.group(1) if m else "0"


def wrap_degrees(a):
    return (a + 180.0) % 360.0 - 180.0


def iou(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ix = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    iy = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    inter = ix * iy
    union = aw * ah + bw * bh - inter
    return inter / union if union > 0 else 0.0


class Track:
    def __init__(self, tid, label, box, now):
        self.id = tid
        self.label = label
        self.category = CATEGORIES.get(label, "other")
        self.box = box
        self.first = self.last = now
        self.hits = 1
        self.confirmed = False
        self.sizes = deque(maxlen=30)
        self.last_approach = 0.0
        self.add_size(now)

    def add_size(self, now):
        _, _, w, h = self.box
        self.sizes.append((now, math.sqrt(max(w * h, 0.0) / (FRAME_W * FRAME_H))))

    @property
    def size(self):
        return self.sizes[-1][1]

    def growth(self, window=0.5):
        """Size change per second over roughly the last `window` seconds."""
        now, size = self.sizes[-1]
        for t, s in self.sizes:
            if now - t <= window:
                return (size - s) / (now - t) if now > t else 0.0
        return 0.0


class Tracker:
    """Greedy box matcher that turns per-frame detections into enter/exit/approach events."""

    def __init__(self, args, emit):
        self.args = args
        self.emit = emit
        self.tracks = []
        self.next_id = 1
        self.event_categories = set(args.categories.split(","))
        self.pass_rate = 0.0  # entries per minute, exponentially smoothed
        self.smoothed = {c: 0.0 for c in STATE_CATEGORIES}
        self.last_decay = None

    def azimuth(self, box):
        x, _, w, _ = box
        xn = (x + w / 2) / FRAME_W
        if self.args.rotate180:
            xn = 1.0 - xn
        # Camera's image-right is clockwise from where it points, whatever the mount
        return wrap_degrees(self.args.facing_deg + (xn - 0.5) * self.args.hfov)

    def update(self, detections, now):
        unmatched = list(self.tracks)
        for label, score, box in sorted(detections, key=lambda d: -d[1]):
            best, best_iou = None, 0.2
            for t in unmatched:
                if t.label == label:
                    o = iou(t.box, box)
                    if o > best_iou:
                        best, best_iou = t, o
            if best is None:
                t = Track(self.next_id, label, box, now)
                self.next_id += 1
                self.tracks.append(t)
            else:
                unmatched.remove(best)
                best.box, best.last = box, now
                best.hits += 1
                best.add_size(now)
                self.check(best, now)

        for t in list(self.tracks):
            if now - t.last > self.args.lost_after:
                self.tracks.remove(t)
                if t.confirmed and t.category in self.event_categories:
                    self.emit("/cam/exit", t.id, t.label, t.category, round(t.last - t.first, 2))

    def check(self, t, now):
        if t.category not in self.event_categories:
            return
        if not t.confirmed and t.hits >= self.args.confirm_hits:
            t.confirmed = True
            self.pass_rate += 60.0 / 20.0
            self.emit("/cam/enter", t.id, t.label, t.category, round(self.azimuth(t.box), 1), round(t.size, 3))
        elif t.confirmed and now - t.last_approach > 2.0:
            g = t.growth()
            if g > self.args.approach_growth:
                t.last_approach = now
                self.emit("/cam/approach", t.id, t.label, t.category,
                          round(self.azimuth(t.box), 1), round(t.size, 3), round(g, 3))

    def state(self, now):
        # clamp: the Pis' clocks can jump when NTP/chrony corrects them
        dt = 0.0 if self.last_decay is None else min(max(now - self.last_decay, 0.0), 5.0)
        self.last_decay = now
        self.pass_rate *= math.exp(-dt / 20.0)
        counts = {c: 0 for c in STATE_CATEGORIES}
        for t in self.tracks:
            if t.confirmed and t.category in counts:
                counts[t.category] += 1
        for c in STATE_CATEGORIES:
            self.smoothed[c] += (counts[c] - self.smoothed[c]) * 0.3
        s = [round(self.smoothed[c], 2) for c in STATE_CATEGORIES]
        return s + [round(sum(s), 2), round(self.pass_rate, 2)]


class DebugStream:
    """Optional MJPEG server showing what the camera sees, with track ids."""

    def __init__(self, port):
        import simplejpeg
        from http import server
        from socketserver import ThreadingMixIn

        self.simplejpeg = simplejpeg
        self.cond = threading.Condition()
        self.jpeg = None
        stream = self

        class Handler(server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                if self.path not in ("/", "/stream.mjpg"):
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Cache-Control", "no-cache, private")
                self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=FRAME")
                self.end_headers()
                try:
                    while True:
                        with stream.cond:
                            stream.cond.wait()
                            jpeg = stream.jpeg
                        self.wfile.write(b"--FRAME\r\nContent-Type: image/jpeg\r\n")
                        self.wfile.write(f"Content-Length: {len(jpeg)}\r\n\r\n".encode() + jpeg + b"\r\n")
                except (BrokenPipeError, ConnectionResetError):
                    pass

        class Server(ThreadingMixIn, server.HTTPServer):
            allow_reuse_address = True
            daemon_threads = True

        threading.Thread(target=Server(("", port), Handler).serve_forever, daemon=True).start()

    def publish(self, frame, tracks, rotate180):
        import numpy as np
        from PIL import Image, ImageDraw

        # Picamera2's "RGB888" is BGR byte order
        img = Image.fromarray(frame[:, :, ::-1])
        draw = ImageDraw.Draw(img)
        for t in tracks:
            x, y, w, h = t.box
            colour = (0, 255, 0) if t.confirmed else (128, 128, 128)
            draw.rectangle([x, y, x + w, y + h], outline=colour, width=2)
            draw.text((x + 3, y + 2), f"#{t.id} {t.label}", fill=colour)
        if rotate180:
            img = img.rotate(180)
        jpeg = self.simplejpeg.encode_jpeg(np.asarray(img), quality=75, colorspace="RGB")
        with self.cond:
            self.jpeg = jpeg
            self.cond.notify_all()


def main():
    args = parse_args()
    args.facing_deg = resolve_facing(args.facing)
    node = resolve_node(args.node)

    from picamera2 import Picamera2
    cams = Picamera2.global_camera_info()
    if not any("imx500" in c.get("Model", "").lower() for c in cams):
        print(f"[camera node {node}] no IMX500 camera found, nothing to do", flush=True)
        return 0

    from picamera2.devices import IMX500

    with open(LABELS_JSON) as f:
        labels = json.load(f)["imx500_object_detection"]["classes"]

    osc = SimpleUDPClient(args.osc_host, args.osc_port)

    def emit(path, *values):
        osc.send_message(path, [node, *values])
        if args.verbose:
            print(path, node, *values, flush=True)

    tracker = Tracker(args, emit)
    stream = DebugStream(args.stream_port) if args.stream_port else None

    # IMX500 must be created before Picamera2 so the network firmware gets loaded
    imx500 = IMX500(MODEL)
    picam2 = Picamera2(imx500.camera_num)
    config = picam2.create_preview_configuration(
        main={"size": (FRAME_W, FRAME_H), "format": "RGB888"}, controls={"FrameRate": 30}, buffer_count=6)
    picam2.start(config)
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    print(f"[camera node {node}] facing {args.facing} ({args.facing_deg:+.0f} deg), "
          f"sending OSC to {args.osc_host}:{args.osc_port}"
          + (f", debug stream on :{args.stream_port}" if stream else ""), flush=True)

    state_period = 1.0 / args.state_hz
    next_state = time.time()
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

            now = time.time()
            outputs = imx500.get_outputs(metadata, add_batch=True)
            if outputs is not None:
                detections = []
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

            if now >= next_state:
                next_state = now + state_period
                emit("/cam/state", *tracker.state(now))
            if stream:
                stream.publish(frame, tracker.tracks, args.rotate180)
    except KeyboardInterrupt:
        pass
    finally:
        picam2.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
