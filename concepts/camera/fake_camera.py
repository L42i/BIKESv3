#!/usr/bin/env python3
"""Fake BIKES camera: sends the same /cam/* OSC messages as camera_osc.py, no camera needed.

For working on camera-reactive sounds on your own laptop. Runs on macOS, Windows
and Linux; the only requirement is python-osc (pip install python-osc).

  python3 fake_camera.py                     # a simulated street, ~12 objects a minute
  python3 fake_camera.py --busy              # rush hour
  python3 fake_camera.py --interactive       # type a key + Enter to send one event
  python3 fake_camera.py --once car          # send one enter (+ exit 3 s later) and quit
  python3 fake_camera.py --port 57121        # if your sclang is on another port

Message formats are documented in README.md.
"""
import argparse
import math
import random
import threading
import time

from pythonosc.udp_client import SimpleUDPClient

from camera_osc import CATEGORIES, DEFAULT_HFOV, STATE_CATEGORIES, resolve_facing

KEYS = {"p": "person", "c": "car", "b": "bicycle", "t": "truck", "u": "bus", "m": "motorcycle", "d": "dog"}
SCENE = [("person", 5), ("car", 4), ("bicycle", 1), ("truck", 1), ("bus", 0.5), ("dog", 0.5)]


class FakeCamera:
    def __init__(self, args):
        self.args = args
        self.client = SimpleUDPClient(args.host, args.port)
        self.facing = resolve_facing(args.facing)
        self.objects = {}  # id -> (label, enter_time, exit_time)
        self.next_id = 1
        self.pass_rate = 0.0
        self.lock = threading.Lock()

    def send(self, path, *values):
        self.client.send_message(path, [self.args.node, *values])
        if path != "/cam/state" or self.args.show_state:
            print(path, self.args.node, *values, flush=True)

    def azimuth(self):
        return round(self.facing + random.uniform(-0.5, 0.5) * DEFAULT_HFOV, 1)

    def enter(self, label, stay=None, approach=False):
        category = CATEGORIES.get(label, "other")
        stay = stay if stay is not None else random.uniform(2, 8)
        closeness = round(random.uniform(0.15, 0.5), 3)
        with self.lock:
            oid = self.next_id
            self.next_id += 1
            self.objects[oid] = (label, time.time(), time.time() + stay)
            self.pass_rate += 60.0 / 20.0
        self.send("/cam/enter", oid, label, category, self.azimuth(), closeness)
        if approach:
            threading.Timer(min(1.5, stay / 2), self.send,
                            ["/cam/approach", oid, label, category, self.azimuth(), round(closeness + 0.25, 3), 0.4]).start()
        return oid

    def tick(self, dt):
        """Expire objects and send /cam/state, like the real service does at 10 Hz."""
        now = time.time()
        with self.lock:
            gone = [(oid, lab, until - since) for oid, (lab, since, until) in self.objects.items() if until <= now]
            for oid, _, _ in gone:
                del self.objects[oid]
            counts = {c: 0 for c in STATE_CATEGORIES}
            for label, _, _ in self.objects.values():
                cat = CATEGORIES.get(label, "other")
                if cat in counts:
                    counts[cat] += 1
            self.pass_rate *= math.exp(-dt / 20.0)
            rate = round(self.pass_rate, 2)
        for oid, label, duration in gone:
            self.send("/cam/exit", oid, label, CATEGORIES.get(label, "other"), round(duration, 2))
        values = [float(counts[c]) for c in STATE_CATEGORIES]
        self.send("/cam/state", *values, float(sum(values)), rate)

    def run_state_loop(self, stop):
        last = time.time()
        while not stop.is_set():
            time.sleep(0.1)
            now = time.time()
            self.tick(now - last)
            last = now


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--host", default="127.0.0.1", help="where your SuperCollider runs")
    ap.add_argument("--port", type=int, default=57120, help="sclang port (NetAddr.langPort)")
    ap.add_argument("--node", default="1", help="bike id to pretend to be")
    ap.add_argument("--facing", default="left")
    ap.add_argument("--rate", type=float, default=12, help="objects per minute in the simulated street")
    ap.add_argument("--busy", action="store_true", help="shortcut for --rate 40")
    ap.add_argument("--interactive", action="store_true", help="send events by typing keys")
    ap.add_argument("--once", metavar="LABEL", help="send a single object (person, car, truck, dog, ...) and quit")
    ap.add_argument("--show-state", action="store_true", help="also print the 10 Hz /cam/state messages")
    args = ap.parse_args()
    if args.busy:
        args.rate = 40

    cam = FakeCamera(args)
    print(f"fake camera (bike {args.node}, facing {args.facing}) -> {args.host}:{args.port}", flush=True)

    if args.once:
        cam.enter(args.once, stay=3.0)
        time.sleep(3.1)
        cam.tick(3.1)
        return

    stop = threading.Event()
    threading.Thread(target=cam.run_state_loop, args=(stop,), daemon=True).start()
    try:
        if args.interactive:
            print("keys: " + "  ".join(f"{k}={v}" for k, v in KEYS.items())
                  + "  a=person approaching  q=quit  (then Enter)", flush=True)
            while True:
                key = input().strip().lower()[:1]
                if key == "q":
                    break
                if key == "a":
                    cam.enter("person", stay=4.0, approach=True)
                elif key in KEYS:
                    cam.enter(KEYS[key])
        else:
            labels, weights = zip(*SCENE)
            while True:
                time.sleep(random.expovariate(args.rate / 60.0))
                label = random.choices(labels, weights)[0]
                cam.enter(label, approach=(label == "person" and random.random() < 0.2))
    except (KeyboardInterrupt, EOFError):
        pass
    finally:
        stop.set()


if __name__ == "__main__":
    main()
