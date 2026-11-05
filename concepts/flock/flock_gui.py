#!/usr/bin/env python3
"""Four-button BIKES Flocking touchscreen. Start FlockSpeech.scd first.

Run: python3 flock_gui.py [--windowed] [--osc-host HOST] [--osc-port PORT]
Requires pygame and python-osc. Escape or the on-screen Close button exits.
Each tap sends /flock/trigger with person, car, flock, or monitored.
Manual triggers replace current speech and bypass sensor cooldowns.
Live annotated preview uses the existing camera process, not a second camera.
Enable it with flock_camera.py --stream-port 8000, or pass the existing playbook
-e 'camera_args="--stream-port 8000"'. Use --camera-url for another bike's feed.
"""
import argparse
import io
import threading
import time
import urllib.request

EVENTS = (
    ("person", "PERSON", ("Person detected.",), (36, 103, 143)),
    ("car", "VEHICLE", ("Vehicle detected.", "Your license plate has been recorded."), (139, 79, 39)),
    ("flock", "FLOCK CAMERA", ("A Flock camera is watching this street.",), (53, 113, 86)),
    ("monitored", "PERSON + CAMERA ZONE", (
        "You are entering a surveilled area.",
        "Please dismount your bike. You are being monitored.",
        "This is a surveilled area."), (111, 68, 136)),
)
OSC_ADDRESS = "/flock/trigger"


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
        camera_rect = pygame.Rect(margin, top, camera_w, height - top - bottom)
        controls_left = camera_rect.right + margin
        cell_w = (width - controls_left - 2 * margin) // 2
        cell_h = (height - top - bottom - margin) // 2
        buttons = [pygame.Rect(controls_left + (i % 2) * (cell_w + margin),
                               top + (i // 2) * (cell_h + margin), cell_w, cell_h)
                   for i in range(4)]
        close = pygame.Rect(width - margin - int(100 * scale), margin,
                            int(100 * scale), int(50 * scale))
        title_font = pygame.font.Font(None, max(18, int(36 * scale)))
        body_font = pygame.font.Font(None, max(12, int(23 * scale)))
        small_font = pygame.font.Font(None, max(12, int(21 * scale)))
        # Fit all sentence labels into the narrower touchscreen buttons once.
        button_text = []
        for _, title, phrases, _ in EVENTS:
            size = max(10, int(26 * scale))
            while True:
                heading = pygame.font.Font(None, size)
                body = pygame.font.Font(None, max(9, int(size * 0.78)))
                lines = [(heading, line) for line in wrapped_lines(title, heading, cell_w - 2 * margin)]
                for phrase in phrases:
                    lines.extend((body, line) for line in wrapped_lines(phrase, body, cell_w - 2 * margin))
                if sum(font.get_linesize() for font, _ in lines) <= cell_h - 2 * margin or size <= 10:
                    break
                size -= 1
            button_text.append(lines)
        preview = CameraPreview(args.camera_url)
        decoded_stamp, camera_image = None, None
        status = "Tap a category to speak. Each tap replaces current speech."
        selected, flash_until = None, 0.0
        clock = pygame.time.Clock()
        running = True

        while running:
            for event in pygame.event.get():
                if event.type == pygame.QUIT or (
                        event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE):
                    running = False
                position = None
                if event.type == pygame.FINGERDOWN:
                    position = (int(event.x * width), int(event.y * height))
                elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                    # SDL also synthesizes mouse events for touch: do not send twice.
                    if not getattr(event, "touch", False):
                        position = event.pos
                if position is None:
                    continue
                if close.collidepoint(position):
                    running = False
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

            screen.fill((16, 22, 30))
            screen.blit(title_font.render("BIKES / FLOCKING", True, "white"), (margin, margin))
            endpoint = f"Speech controls   |   {args.osc_host}:{args.osc_port}"
            screen.blit(small_font.render(endpoint, True, (175, 190, 205)),
                        (margin, int(59 * scale)))
            pygame.draw.rect(screen, (55, 64, 76), close, border_radius=8)
            label = body_font.render("Close", True, "white")
            screen.blit(label, label.get_rect(center=close.center))
            pygame.draw.rect(screen, (8, 12, 18), camera_rect, border_radius=14)
            jpeg, stamp, camera_status = preview.snapshot()
            fresh = jpeg is not None and time.monotonic() - stamp < 3
            video_rect = camera_rect.inflate(-2 * margin, -2 * margin)
            video_rect.top += int(30 * scale)
            video_rect.height -= int(30 * scale)
            if fresh and stamp != decoded_stamp:
                try:
                    frame = pygame.image.load(io.BytesIO(jpeg), "camera.jpg").convert()
                    ratio = min(video_rect.width / frame.get_width(), video_rect.height / frame.get_height())
                    camera_image = pygame.transform.smoothscale(frame, (
                        max(1, int(frame.get_width() * ratio)), max(1, int(frame.get_height() * ratio))))
                    decoded_stamp = stamp
                except (pygame.error, ValueError):
                    camera_image = None
                    camera_status = "Cannot decode camera image"
            if fresh and camera_image is not None:
                screen.blit(camera_image, camera_image.get_rect(center=video_rect.center))
            else:
                if jpeg is not None and not fresh:
                    camera_status = "Camera feed stalled - waiting"
                help_text = "Enable the camera stream with --stream-port 8000. Speech buttons remain available."
                for i, line in enumerate(wrapped_lines(help_text, small_font, video_rect.width)):
                    screen.blit(small_font.render(line, True, (175, 190, 205)),
                                (video_rect.left, video_rect.centery + i * small_font.get_linesize()))
            for i, line in enumerate(wrapped_lines(camera_status, small_font, camera_rect.width - 2 * margin)):
                screen.blit(small_font.render(line, True, (175, 220, 205)),
                            (camera_rect.left + margin, camera_rect.top + margin + i * small_font.get_linesize()))
            for index, (key, title, phrases, color) in enumerate(EVENTS):
                rect = buttons[index]
                active = selected == index and time.monotonic() < flash_until
                fill = tuple(min(255, c + 45) for c in color) if active else color
                pygame.draw.rect(screen, fill, rect, border_radius=14)
                lines = button_text[index]
                total = sum(font.get_linesize() for font, _ in lines)
                y = rect.centery - total // 2
                for font, line in lines:
                    label = font.render(line, True, "white")
                    screen.blit(label, (rect.centerx - label.get_width() // 2, y))
                    y += font.get_linesize()
            # Sent means UDP was sent; it is not a playback acknowledgement.
            for i, line in enumerate(wrapped_lines(status, small_font, width - 2 * margin)[:2]):
                screen.blit(small_font.render(line, True, (210, 220, 230)),
                            (margin, height - bottom + int(10 * scale) + i * small_font.get_linesize()))
            pygame.display.flip()
            clock.tick(30)
    finally:
        if preview is not None:
            preview.close()
        pygame.quit()


if __name__ == "__main__":
    main()
