#!/usr/bin/env python3
"""Four-button BIKES Flocking touchscreen. Start FlockSpeech.scd first.

Run: python3 flock_gui.py [--windowed] [--osc-host HOST] [--osc-port PORT]
Requires pygame and python-osc. Close (or Escape) asks for confirmation before
exiting; the confirmation cancels itself after 10 s.
Each tap sends /flock/trigger with person, car, flock, or monitored.
Manual triggers replace current speech and bypass sensor cooldowns.
FLOCK ON/OFF replaces the GPS zone decision: it sends /flock/zone 1 (inside a
Flock camera zone) or 0 (outside) on every tap and again every 2 s. It starts
OFF, and closing the GUI sends 0.
Live annotated preview uses the existing camera process, not a second camera.
Enable it with flock_camera.py --stream-port 8000, or pass the existing playbook
-e 'camera_args="--stream-port 8000"'. Use --camera-url for another bike's feed.
Offline Atlanta streets: maps/atlanta_streets.sqlite (bundled, no tile requests).
GPS: reads ~/Desktop/flock_gps.log produced by flock_gps.py, which owns the
u-blox serial device /dev/ttyACM0 at 9600 baud. No second serial reader is opened.
Use --gps-log PATH or --map-file PATH to override these local files.
"""
import argparse
import io
import json
import math
from pathlib import Path
import re
import sqlite3
import threading
import time
import urllib.request

# High-visibility palette for direct sunlight: black on white, bright safety
# colours under black text, thick black outlines. Every text/fill pair is >= 7:1.
INK = (0, 0, 0)
PAPER = (255, 255, 255)
SOFT_INK = (45, 45, 45)
ON_GREEN = (0, 205, 80)
WARN_YELLOW = (255, 214, 0)
CLOSE_RED = (180, 0, 0)  # white text on it is 7.6:1
CLOSE_CONFIRM_TIMEOUT = 10.0  # an unanswered close confirmation cancels itself

EVENTS = (
    ("person", "PERSON", ("Person detected.", "The bikes are watching you."), (255, 214, 0)),
    ("car", "VEHICLE", ("Vehicle detected.", "Your license plate has been recorded."), (255, 145, 0)),
    ("flock", "FLOCK CAMERA", ("A Flock camera is watching this street.",), (0, 205, 255)),
    ("monitored", "PERSON + CAMERA ZONE", (
        "You are entering a surveilled area.",
        "Please dismount your bike. You are being monitored.",
        "This is a surveilled area."), (255, 120, 190)),
)
OSC_ADDRESS = "/flock/trigger"
ZONE_ADDRESS = "/flock/zone"
ZONE_HEARTBEAT = 2.0  # same resend interval as the camera and GPS senders


class FlockZoneToggle:
    """FLOCK ON = inside a Flock camera zone, OFF = outside. Replaces the GPS zone.

    UDP can drop packets and sclang may restart, so the state is resent every
    ZONE_HEARTBEAT seconds; FlockSpeech.scd only reacts to a 0 -> 1 change.
    """

    def __init__(self, client):
        self.client = client
        self.on = False
        self.next_send = 0.0
        self.error = None

    def send(self):
        self.next_send = time.monotonic() + ZONE_HEARTBEAT
        self.client.send_message(ZONE_ADDRESS, int(self.on))
        self.error = None

    def toggle(self):
        self.on = not self.on
        self.send()

    def heartbeat(self):
        if time.monotonic() < self.next_send:
            return
        try:
            self.send()
        except OSError as error:
            if self.error is None:
                print(f"Could not send {ZONE_ADDRESS}: {error}", flush=True)
            self.error = error

    def close(self):
        self.on = False
        try:
            self.send()
        except OSError:
            pass


class GPSLogReader:
    """Follow existing unbuffered GPS output without consuming serial bytes.

    File modification time bounds freshness even on startup. A log left over
    from yesterday is never treated as a current fix. Reads are bounded and
    tolerate partial lines, restarts, truncation and replacement.
    """
    FIX = re.compile(r"^fix ([+-]?\d+(?:\.\d+)?),([+-]?\d+(?:\.\d+)?) ")
    TIMEOUT = 5.0  # matches flock_gps.py's default --gps-timeout

    def __init__(self, path):
        self.path = Path(path).expanduser()
        self.offset = 0
        self.identity = None
        self.modified = None
        self.partial = b""
        self.position = None
        self.fix_at = float('-inf')
        self.valid = False
        self.simulated = False
        self.status = "Waiting for GPS log"
        self.next_poll = 0.0

    def consume(self, line, observed):
        match = self.FIX.match(line)
        if match:
            lat, lon = map(float, match.groups())
            if -90 <= lat <= 90 and -180 <= lon <= 180:
                self.position, self.fix_at, self.valid = (lat, lon), observed, True
                self.status = "GPS fix"
        elif any(word in line for word in (
                "Waiting for a valid GPS fix", "No recent valid GPS fix",
                "GPS reports no valid fix", "Sent final OSC", "GPS serial error:",
                "GPS program stopped", "GPS/OSC error:", "Traceback")):
            self.valid = False
            self.status = "No GPS fix"
        elif line.startswith("Simulating:"):
            self.simulated = True

    def poll(self):
        now = time.monotonic()
        if now < self.next_poll:
            return
        self.next_poll = now + 0.25
        try:
            with self.path.open('rb') as stream:
                import os
                stat = os.fstat(stream.fileno())
                identity = (stat.st_dev, stat.st_ino)
                reset = (identity != self.identity or stat.st_size < self.offset or
                         (stat.st_size == self.offset and stat.st_mtime_ns != self.modified))
                if reset:
                    self.valid = False
                    self.simulated = b'Simulating:' in stream.read(2048)
                    self.offset = max(0, stat.st_size - 65536)
                    self.partial = b''
                stream.seek(self.offset)
                if reset and self.offset:
                    stream.readline()  # discard the first incomplete line of a tail
                data = stream.read(65536)
                self.offset = stream.tell()
                self.identity, self.modified = identity, stat.st_mtime_ns
            # Do not present a backlog as live; catch up at the next poll.
            if self.offset < stat.st_size:
                self.offset = max(0, stat.st_size - 65536)
                self.identity = None
                self.valid = False
                self.status = "Catching up with GPS"
                return
            lines = (self.partial + data).split(b'\n')
            self.partial = lines.pop()[-8192:]
            observed = now - max(0.0, time.time() - stat.st_mtime)
            for line in lines:
                self.consume(line.decode('utf-8', errors='replace').strip(), observed)
        except OSError:
            self.valid = False
            self.status = "GPS log unavailable"

    def is_live(self):
        return self.valid and time.monotonic() - self.fix_at <= self.TIMEOUT


def meters_per_degree(latitude):
    """WGS84 local east/north scale, appropriate for a 100 m viewport."""
    phi = math.radians(latitude)
    e2 = 6.69437999014e-3
    denominator = 1 - e2 * math.sin(phi) ** 2
    north = 6378137 * (1 - e2) / denominator ** 1.5 * math.pi / 180
    east = 6378137 / math.sqrt(denominator) * math.cos(phi) * math.pi / 180
    return east, north


def map_bounds(latitude, longitude):
    east, north = meters_per_degree(latitude)
    return (longitude - 50 / east, latitude - 50 / north,
            longitude + 50 / east, latitude + 50 / north)


class OfflineStreetMap:
    """Read-only spatially indexed street geometry; never accesses the network."""
    def __init__(self, path):
        self.db = None
        self.error = None
        self.bounds = None
        self.key = None
        self.roads = []
        try:
            self.db = sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True)
            self.bounds = json.loads(self.db.execute(
                "SELECT value FROM metadata WHERE name='bounds'").fetchone()[0])
        except (OSError, sqlite3.Error, TypeError, ValueError) as error:
            self.error = "Offline map unavailable"
            print(f"Offline map: {error}", flush=True)

    def streets(self, position):
        if self.db is None or self.error:
            return []
        if self.key != position:
            west, south, east, north = map_bounds(*position)
            try:
                rows = self.db.execute(
                    "SELECT r.name,r.kind,r.geometry FROM roads r JOIN road_index i ON r.id=i.id "
                    "WHERE i.max_lon>=? AND i.min_lon<=? AND i.max_lat>=? AND i.min_lat<=?",
                    (west, east, south, north))
                self.roads = [(name, kind, json.loads(geometry)) for name, kind, geometry in rows]
                self.key = position
            except (sqlite3.Error, ValueError) as error:
                self.error = "Offline map unreadable"
                self.roads = []
                print(f"Offline map: {error}", flush=True)
        return self.roads

    def covers(self, position):
        if self.bounds is None:
            return False
        west, south, east, north = map_bounds(*position)
        a, b, c, d = self.bounds
        return a <= west and b <= south and c >= east and d >= north

    def close(self):
        if self.db is not None:
            self.db.close()


def draw_location(screen, rect, gps, street_map, font, scale):
    import pygame
    pygame.draw.rect(screen, PAPER, rect, border_radius=12)
    pygame.draw.rect(screen, INK, rect, width=max(3, int(4 * scale)), border_radius=12)
    pad = max(8, int(12 * scale))
    line_h = font.get_linesize()
    title = font.render("ATLANTA / OFFLINE / 100 m x 100 m", True, INK)
    screen.blit(title, (rect.x + pad, rect.y + pad))
    side = min(rect.height - 2 * pad - 2 * line_h, rect.width - 2 * pad)
    area = pygame.Rect(rect.x + pad, rect.y + pad + line_h, side, side)
    pygame.draw.rect(screen, (240, 240, 228), area)
    pygame.draw.rect(screen, INK, area, width=2)
    position = gps.position
    live = gps.is_live()
    status = ("SIMULATED" if gps.simulated else "LIVE GPS") if live else "NO LIVE FIX"
    if position is not None:
        latitude, longitude = position
        east, north = meters_per_degree(latitude)
        def pixel(point):
            lon, lat = point
            return (area.centerx + (lon - longitude) * east * side / 100,
                    area.centery - (lat - latitude) * north * side / 100)
        old_clip = screen.get_clip()
        screen.set_clip(area)
        names = set()
        label_boxes = []
        road_labels = []
        for name, kind, geometry in street_map.streets(position):
            points = [pixel(point) for point in geometry]
            if len(points) < 2:
                continue
            path = kind in ('footway', 'path', 'cycleway', 'steps', 'pedestrian')
            thickness = max(1, round(side / 100 * (1 if path else 4)))
            pygame.draw.lines(screen, (40, 40, 40), False, points, thickness + 2)
            pygame.draw.lines(screen, PAPER if not path else (150, 100, 30),
                              False, points, thickness)
            if name and name not in names:
                for p, q in zip(points, points[1:]):
                    clipped = area.clipline(p, q)
                    if clipped:
                        start, end = clipped
                        mid = ((start[0]+end[0])/2, (start[1]+end[1])/2)
                        label = font.render(name, True, INK, (240, 240, 228))
                        box = label.get_rect(center=mid)
                        box.clamp_ip(area)
                        if label.get_width() <= area.width and not any(box.colliderect(b) for b in label_boxes):
                            road_labels.append((label, box))
                            label_boxes.append(box)
                            names.add(name)
                        break
        for label, box in road_labels:
            screen.blit(label, box)
        pygame.draw.circle(screen, INK, area.center, max(8, int(10*scale)))
        pygame.draw.circle(screen, (0, 90, 255) if live else (130, 130, 130), area.center, max(6, int(8*scale)))
        pygame.draw.circle(screen, PAPER, area.center, max(2, int(3*scale)))
        screen.set_clip(old_clip)
    else:
        label = font.render("Waiting for GPS fix", True, INK)
        screen.blit(label, label.get_rect(center=area.center))
    # North-up, with a ground-distance scale. The square spans +/-50 m.
    screen.blit(font.render("N", True, INK), (area.x+4, area.y+3))
    bar = round(side / 5)  # 20 metres
    pygame.draw.line(screen, INK, (area.x+6, area.bottom-7), (area.x+6+bar, area.bottom-7), 3)
    screen.blit(font.render("20 m", True, INK), (area.x+6, area.bottom-7-line_h))
    info = [status]
    if position:
        info += [f"{position[0]:.6f}", f"{position[1]:.6f}", "Bike at center" if live else "Last known fix"]
    else:
        info += ["Waiting for", "GPS sensor"]
    if street_map.error:
        info += [street_map.error]
    elif position and not street_map.covers(position):
        info += ["Outside bundled", "map coverage"]
    info_x = area.right + pad
    info_width = rect.right - pad - info_x
    y = area.top
    for text in info:
        for line in wrapped_lines(text, font, max(20, info_width)):
            screen.blit(font.render(line, True, INK), (info_x, y))
            y += line_h
    attribution = font.render("Map: City of Atlanta GIS / StreetCenterline", True, SOFT_INK)
    screen.blit(attribution, (rect.x+pad, rect.bottom-pad-line_h))


def mjpeg_frames(stream):
    """Read bounded Content-Length parts emitted by camera_osc.DebugStream."""
    while True:
        line = stream.readline(8192)
        if not line:
            return
        if not line.startswith(b"--FRAME"):
            continue
        length = None
        for _ in range(32):
            line = stream.readline(8192)
            if not line:
                return
            if line in (b"\r\n", b"\n"):
                break
            name, _, value = line.partition(b":")
            if name.lower() == b"content-length":
                length = int(value.strip())
        else:
            raise ValueError("Too many camera frame headers")
        if length is None or not 0 < length <= 4 * 1024 * 1024:
            raise ValueError("Invalid camera frame length")
        data = bytearray()
        while len(data) < length:
            chunk = stream.read(length - len(data))
            if not chunk:
                return
            data.extend(chunk)
        yield bytes(data)


class CameraPreview:
    """Background reader with reconnects and one latest frame (no growing queue)."""

    def __init__(self, url):
        self.url = url
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.jpeg = None
        self.updated = 0.0
        self.status = "Connecting to camera..."
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def snapshot(self):
        with self.lock:
            return self.jpeg, self.updated, self.status

    def run(self):
        while not self.stop.is_set():
            try:
                # Ignore desktop HTTP proxies for the local bike's video feed.
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                with opener.open(self.url, timeout=3) as response:
                    for jpeg in mjpeg_frames(response):
                        if self.stop.is_set():
                            return
                        with self.lock:
                            self.jpeg, self.updated = jpeg, time.monotonic()
                            self.status = "LIVE CAMERA"
                    raise OSError("Camera stream ended")
            except (OSError, ValueError) as error:
                with self.lock:
                    self.jpeg = None
                    self.status = "Camera unavailable - reconnecting"
                print(f"Camera preview: {error}", flush=True)
                self.stop.wait(2)

    def close(self):
        self.stop.set()
        self.thread.join(timeout=0.2)


def draw_zone_toggle(screen, rect, on, font, scale):
    """A switch: bright green with the knob right for ON, white with the knob left for OFF."""
    import pygame
    pygame.draw.rect(screen, ON_GREEN if on else PAPER, rect, border_radius=8)
    pygame.draw.rect(screen, INK, rect, width=max(3, int(4 * scale)), border_radius=8)
    pad = max(8, int(11 * scale))
    track_h = max(12, rect.height - 2 * pad)
    track = pygame.Rect(0, 0, int(track_h * 1.8), track_h)
    track.midright = (rect.right - pad, rect.centery)
    pygame.draw.rect(screen, INK, track, border_radius=track_h // 2)
    knob_x = track.right - track_h // 2 if on else track.left + track_h // 2
    pygame.draw.circle(screen, ON_GREEN if on else PAPER, (knob_x, track.centery), max(4, track_h // 2 - 3))
    label = font.render("FLOCK ON" if on else "FLOCK OFF", True, INK)
    screen.blit(label, label.get_rect(center=((rect.left + track.left) // 2, rect.centery)))


def close_dialog_rects(width, height, scale):
    """Dialog box, Cancel and Close buttons for the close confirmation."""
    import pygame
    box = pygame.Rect(0, 0, int(640 * scale), int(330 * scale))
    box.center = (width // 2, height // 2)
    pad = int(30 * scale)
    button_w, button_h = (box.width - 3 * pad) // 2, int(100 * scale)
    cancel = pygame.Rect(box.left + pad, box.bottom - pad - button_h, button_w, button_h)
    confirm = pygame.Rect(cancel.right + pad, cancel.top, button_w, button_h)
    return box, cancel, confirm


def draw_close_dialog(screen, rects, fonts, scale):
    """Dimmed screen with a white box: Cancel (left) and a red Close (right)."""
    import pygame
    box, cancel, confirm = rects
    title_font, body_font = fonts
    border = max(3, int(5 * scale))
    shade = pygame.Surface(screen.get_size(), pygame.SRCALPHA)
    shade.fill((0, 0, 0, 170))
    screen.blit(shade, (0, 0))
    pygame.draw.rect(screen, PAPER, box, border_radius=16)
    pygame.draw.rect(screen, INK, box, width=border, border_radius=16)
    y = box.top + int(28 * scale)
    for font, text in ((title_font, "Close the Flock screen?"),
                       (body_font, "Speech, camera and GPS keep running."),
                       (body_font, "Tap Start Flock to open this screen again.")):
        label = font.render(text, True, INK)
        screen.blit(label, label.get_rect(midtop=(box.centerx, y)))
        y += font.get_linesize() + int(6 * scale)
    for rect, fill, text, colour in ((cancel, PAPER, "Cancel", INK),
                                     (confirm, CLOSE_RED, "Close", PAPER)):
        pygame.draw.rect(screen, fill, rect, border_radius=12)
        pygame.draw.rect(screen, INK, rect, width=border, border_radius=12)
        label = title_font.render(text, True, colour)
        screen.blit(label, label.get_rect(center=rect.center))


def send_trigger(client, event):
    if event not in {item[0] for item in EVENTS}:
        raise ValueError(f"Unknown speech event: {event}")
    client.send_message(OSC_ADDRESS, event)


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--osc-host", default="127.0.0.1")
    parser.add_argument("--osc-port", type=int, default=57120)
    parser.add_argument("--windowed", action="store_true", help="use a 1024 x 600 window")
    parser.add_argument("--camera-url", default="http://127.0.0.1:8000/stream.mjpg",
                        help="existing camera MJPEG stream URL")
    parser.add_argument("--gps-log", default=str(Path.home() / 'Desktop' / 'flock_gps.log'),
                        help="local log from the existing flock_gps.py process")
    parser.add_argument("--map-file", default=str(Path(__file__).resolve().parent / 'maps' / 'atlanta_streets.sqlite'),
                        help="bundled offline Atlanta street database")
    args = parser.parse_args()
    if not 1 <= args.osc_port <= 65535:
        parser.error("--osc-port must be between 1 and 65535")
    if not args.camera_url.startswith(("http://", "https://")):
        parser.error("--camera-url must use http:// or https://")
    return args


def wrapped_lines(text, font, width):
    lines, line = [], ""
    for word in text.split():
        candidate = (line + " " + word).strip()
        if line and font.size(candidate)[0] > width:
            lines.append(line)
            line = word
        else:
            line = candidate
    return lines + ([line] if line else [])


def main():
    args = arguments()
    import pygame
    from pythonosc.udp_client import SimpleUDPClient

    client = SimpleUDPClient(args.osc_host, args.osc_port)
    pygame.init()
    preview = None
    street_map = None
    zone = None
    try:
        screen = pygame.display.set_mode(
            (1024, 600) if args.windowed else (0, 0),
            0 if args.windowed else pygame.FULLSCREEN)
        pygame.display.set_caption("BIKES | Flocking")
        width, height = screen.get_size()
        scale = min(width / 1024, height / 600)
        margin = max(10, int(20 * scale))
        top, bottom = int(94 * scale), int(64 * scale)
        camera_w = int((width - 3 * margin) * 0.40)
        left_height = height - top - bottom
        camera_h = int((left_height - margin) * 0.55)
        camera_rect = pygame.Rect(margin, top, camera_w, camera_h)
        map_rect = pygame.Rect(margin, camera_rect.bottom + margin, camera_w, left_height - camera_h - margin)
        controls_left = camera_rect.right + margin
        cell_w = (width - controls_left - 2 * margin) // 2
        cell_h = (height - top - bottom - margin) // 2
        buttons = [pygame.Rect(controls_left + (i % 2) * (cell_w + margin),
                               top + (i // 2) * (cell_h + margin), cell_w, cell_h)
                   for i in range(4)]
        close = pygame.Rect(width - margin - int(100 * scale), margin,
                            int(100 * scale), int(50 * scale))
        zone_rect = pygame.Rect(close.left - margin - int(250 * scale), margin,
                                int(250 * scale), close.height)
        # Larger than a desk UI: the screen is read at arm's length in sunlight.
        zone_font = pygame.font.Font(None, max(16, int(34 * scale)))
        title_font = pygame.font.Font(None, max(20, int(44 * scale)))
        body_font = pygame.font.Font(None, max(14, int(28 * scale)))
        small_font = pygame.font.Font(None, max(13, int(25 * scale)))
        map_font = pygame.font.Font(None, max(12, int(20 * scale)))
        border = max(3, int(4 * scale))
        gps = GPSLogReader(args.gps_log)
        street_map = OfflineStreetMap(args.map_file)
        # Fit all sentence labels into the narrower touchscreen buttons once.
        button_text = []
        for _, title, phrases, _ in EVENTS:
            size = max(10, int(34 * scale))
            while True:
                heading = pygame.font.Font(None, size)
                body = pygame.font.Font(None, max(9, int(size * 0.8)))
                lines = [(heading, line) for line in wrapped_lines(title, heading, cell_w - 2 * margin)]
                for phrase in phrases:
                    lines.extend((body, line) for line in wrapped_lines(phrase, body, cell_w - 2 * margin))
                if sum(font.get_linesize() for font, _ in lines) <= cell_h - 2 * margin or size <= 10:
                    break
                size -= 1
            button_text.append(lines)
        preview = CameraPreview(args.camera_url)
        zone = FlockZoneToggle(client)
        decoded_stamp, camera_image = None, None
        status = "Tap a category to speak. Each tap replaces current speech."
        selected, flash_until = None, 0.0
        dialog = close_dialog_rects(width, height, scale)
        confirm_until = None  # set while the close confirmation is open
        clock = pygame.time.Clock()
        running = True

        while running:
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    running = False
                elif event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
                    # Escape opens the same confirmation; Escape again cancels it.
                    confirm_until = None if confirm_until else time.monotonic() + CLOSE_CONFIRM_TIMEOUT
                position = None
                if event.type == pygame.FINGERDOWN:
                    position = (int(event.x * width), int(event.y * height))
                elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                    # SDL also synthesizes mouse events for touch: do not send twice.
                    if not getattr(event, "touch", False):
                        position = event.pos
                if position is None:
                    continue
                if confirm_until is not None:
                    # While the confirmation is open nothing else reacts to taps.
                    if dialog[2].collidepoint(position):
                        running = False
                    else:
                        confirm_until = None
                        status = "Close cancelled."
                    continue
                if close.collidepoint(position):
                    confirm_until = time.monotonic() + CLOSE_CONFIRM_TIMEOUT
                    continue
                if zone_rect.collidepoint(position):
                    try:
                        zone.toggle()
                        status = (("FLOCK ON: inside a Flock camera zone, a person plays the "
                                   "surveilled-area speech" if zone.on else
                                   "FLOCK OFF: outside every Flock camera zone, a person plays "
                                   "the person speech") + f" | {time.strftime('%H:%M:%S')}")
                    except OSError as error:
                        status = f"Could not send FLOCK {'ON' if zone.on else 'OFF'}: {error}"
                    print(status, flush=True)
                    continue
                for index, rect in enumerate(buttons):
                    if rect.collidepoint(position):
                        key, label, _, _ = EVENTS[index]
                        try:
                            send_trigger(client, key)
                            status = f"Sent: {label} | {time.strftime('%H:%M:%S')}"
                            selected, flash_until = index, time.monotonic() + 0.25
                        except OSError as error:
                            status = f"Could not send: {error}"
                        print(status, flush=True)
                        break

            screen.fill(PAPER)
            screen.blit(title_font.render("BIKES / FLOCKING", True, INK), (margin, margin))
            endpoint = f"Speech controls   |   {args.osc_host}:{args.osc_port}"
            screen.blit(small_font.render(endpoint, True, SOFT_INK),
                        (margin, int(60 * scale)))
            pygame.draw.rect(screen, PAPER, close, border_radius=8)
            pygame.draw.rect(screen, INK, close, width=border, border_radius=8)
            label = body_font.render("Close", True, INK)
            screen.blit(label, label.get_rect(center=close.center))
            zone.heartbeat()
            draw_zone_toggle(screen, zone_rect, zone.on, zone_font, scale)
            pygame.draw.rect(screen, INK, camera_rect, border_radius=14)
            jpeg, stamp, camera_status = preview.snapshot()
            fresh = jpeg is not None and time.monotonic() - stamp < 3
            # Fill the panel, preserving aspect ratio with a centered crop.
            video_rect = camera_rect.inflate(-2 * border, -2 * border)
            if fresh and stamp != decoded_stamp:
                try:
                    frame = pygame.image.load(io.BytesIO(jpeg), "camera.jpg").convert()
                    ratio = max(video_rect.width / frame.get_width(), video_rect.height / frame.get_height())
                    camera_image = pygame.transform.smoothscale(frame, (
                        max(1, int(frame.get_width() * ratio)), max(1, int(frame.get_height() * ratio))))
                    decoded_stamp = stamp
                except (pygame.error, ValueError):
                    camera_image = None
                    camera_status = "Cannot decode camera image"
            if fresh and camera_image is not None:
                previous_clip = screen.get_clip()
                screen.set_clip(video_rect)
                screen.blit(camera_image, camera_image.get_rect(center=video_rect.center))
                screen.set_clip(previous_clip)
            else:
                if jpeg is not None and not fresh:
                    camera_status = "Camera feed stalled - waiting"
                help_text = "No video. Enable --stream-port 8000."
                for i, line in enumerate(wrapped_lines(help_text, small_font, video_rect.width)):
                    screen.blit(small_font.render(line, True, PAPER),
                                (video_rect.left + 6, video_rect.bottom - (i + 1) * small_font.get_linesize() - 6))
            for i, line in enumerate(wrapped_lines(camera_status, small_font, camera_rect.width - 2 * margin)):
                screen.blit(small_font.render(f" {line} ", True, INK, WARN_YELLOW),
                            (camera_rect.left + 8, camera_rect.top + 6 + i * small_font.get_linesize()))
            gps.poll()
            draw_location(screen, map_rect, gps, street_map, map_font, scale)
            for index, (key, title, phrases, color) in enumerate(EVENTS):
                rect = buttons[index]
                active = selected == index and time.monotonic() < flash_until
                # A tap flashes the button inverted (black), which reads even in glare.
                pygame.draw.rect(screen, INK if active else color, rect, border_radius=14)
                pygame.draw.rect(screen, INK, rect, width=border, border_radius=14)
                lines = button_text[index]
                total = sum(font.get_linesize() for font, _ in lines)
                y = rect.centery - total // 2
                for font, line in lines:
                    label = font.render(line, True, color if active else INK)
                    screen.blit(label, (rect.centerx - label.get_width() // 2, y))
                    y += font.get_linesize()
            # Sent means UDP was sent; it is not a playback acknowledgement.
            for i, line in enumerate(wrapped_lines(status, small_font, width - 2 * margin)[:2]):
                screen.blit(small_font.render(line, True, INK),
                            (margin, height - bottom + int(10 * scale) + i * small_font.get_linesize()))
            if confirm_until is not None:
                if time.monotonic() > confirm_until:
                    confirm_until = None
                    status = "Close cancelled."
                else:
                    draw_close_dialog(screen, dialog, (title_font, body_font), scale)
            pygame.display.flip()
            clock.tick(30)
    finally:
        if zone is not None:
            zone.close()  # nobody can switch the zone off once the GUI is gone
        if preview is not None:
            preview.close()
        if street_map is not None:
            street_map.close()
        pygame.quit()


if __name__ == "__main__":
    main()
