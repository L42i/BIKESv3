#!/usr/bin/env python3
"""Print every OSC message that arrives. Debug tool for the BIKES Flocking senders.

Only run it while sclang is not using the same port.

Usage: python3 osc_monitor.py [--port 57120]
"""
import argparse
import time

from pythonosc.dispatcher import Dispatcher
from pythonosc.osc_server import ThreadingOSCUDPServer


def show(address, *args):
    now = time.time()
    stamp = time.strftime("%H:%M:%S", time.localtime(now))
    print(f"{stamp}.{int(now * 1000) % 1000:03d} {address} {list(args)}", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=57120)
    args = ap.parse_args()

    dispatcher = Dispatcher()
    dispatcher.set_default_handler(show)
    server = ThreadingOSCUDPServer((args.host, args.port), dispatcher)
    print(f"Listening for OSC on {args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
