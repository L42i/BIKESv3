import pygame
import threading
from pythonosc import udp_client, dispatcher, osc_server

# --- OSC ---
osc_client = udp_client.SimpleUDPClient("127.0.0.1", 57120)

# --- Music ---
NOTES = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
SCALES = {
    "Major":      [0,2,4,5,7,9,11],
    "Minor":      [0,2,3,5,7,8,10],
    "Dorian":     [0,2,3,5,7,9,10],
    "Mixolydian": [0,2,4,5,7,9,10],
}

# --- State ---
root_idx       = 0
scale_name     = "Major"
current_degree = 0
active_button  = -1

# --- OSC receiver ---
def remote_chord_handler(address, r_name, s_name, degree):
    global root_idx, scale_name, current_degree
    try:
        root_idx       = NOTES.index(r_name)
        scale_name     = s_name
        current_degree = (degree - 1) if degree > 0 else 0
    except ValueError:
        pass

disp = dispatcher.Dispatcher()
disp.map("/remoteChord", remote_chord_handler)
server = osc_server.ThreadingOSCUDPServer(("0.0.0.0", 57121), disp)
threading.Thread(target=server.serve_forever, daemon=True).start()

# ---------------------------------------------------------------------------
# PALETTE
# ---------------------------------------------------------------------------
C_BG      = (247, 236, 203)
C_SURFACE = (255, 255, 255)
C_BORDER  = (200, 196, 190)
C_INK     = (26, 25, 22)
C_PRESS   = (1, 24, 87)
C_MUTED   = (136, 135, 128)
C_ACCENT  = (252, 226, 28)
C_ACT_SUB = (100, 160, 130)
C_STATUS_BG  = (255, 255, 255)
C_STATUS_TXT = C_ACCENT

# ---------------------------------------------------------------------------
pygame.init()
info = pygame.display.Info()
W, H = info.current_w, info.current_h
screen = pygame.display.set_mode((W, H), pygame.FULLSCREEN)
pygame.display.set_caption("Voice Pad — Receiver")
pygame.mouse.set_visible(False)
clock = pygame.time.Clock()

font_func  = pygame.font.SysFont("Arial", 16, bold=True)
font_note  = pygame.font.SysFont("Arial", 96, bold=True)
font_sm    = pygame.font.SysFont("Arial", 15, bold=True)

HEADER = 68
MARGIN = 16
GAP    = 10
FUNC_NAMES = ["ROOT", "3RD", "5TH", "7TH"]

def pad_rects():
    gw = W - 2*MARGIN
    gh = H - HEADER - MARGIN
    pw = (gw - GAP) // 2
    ph = (gh - GAP) // 2
    return [
        pygame.Rect(MARGIN + (i % 2) * (pw + GAP), HEADER + (i // 2) * (ph + GAP), pw, ph)
        for i in range(4)
    ]

def get_note_label(btn_idx):
    intervals  = SCALES[scale_name]
    voicing    = [0, 2, 4, 6]
    scale_step = (current_degree + voicing[btn_idx]) % 7
    semi       = intervals[scale_step]
    return NOTES[(root_idx + semi) % 12]

def draw_rounded_rect(surf, color, rect, radius, border=0, border_color=None):
    pygame.draw.rect(surf, color, rect, border_radius=radius)
    if border and border_color:
        pygame.draw.rect(surf, border_color, rect, border, border_radius=radius)

def toggle_pad(i):
    global active_button
    if active_button == i:
        osc_client.send_message("/localChord", [i, 0])
        active_button = -1
    else:
        if active_button != -1:
            osc_client.send_message("/localChord", [active_button, 0])
        active_button = i
        osc_client.send_message("/localChord", [i, 1])

running = True
while running:
    screen.fill(C_BG)
    rects = pad_rects()

    for event in pygame.event.get():
        if event.type == pygame.QUIT:
            running = False

        elif event.type == pygame.MOUSEBUTTONDOWN or event.type == pygame.FINGERDOWN:
            if event.type == pygame.MOUSEBUTTONDOWN:
                tx, ty = event.pos
            else:
                tx = int(event.x * W)
                ty = int(event.y * H)

            for i, rect in enumerate(rects):
                if rect.collidepoint(tx, ty):
                    toggle_pad(i)
                    break

        elif event.type == pygame.KEYDOWN:
            if event.key == pygame.K_1:
                toggle_pad(0)
            elif event.key == pygame.K_2:
                toggle_pad(1)
            elif event.key == pygame.K_3:
                toggle_pad(2)
            elif event.key == pygame.K_4:
                toggle_pad(3)
            elif event.key == pygame.K_ESCAPE:
                running = False

    # --- Status bar ---
    status_rect = pygame.Rect(MARGIN, 16, W - 2*MARGIN, 36)
    draw_rounded_rect(screen, C_STATUS_BG, status_rect, 6)

    # Live indicator dot
    pygame.draw.circle(screen, C_ACCENT, (MARGIN + 18, 34), 5)

    status_str = f"{NOTES[root_idx]} {scale_name}  ·  Degree {current_degree + 1}"
    s_txt = font_sm.render(status_str, True, C_INK)
    screen.blit(s_txt, (MARGIN + 32, 25))

    # --- Draw pads ---
    for i, rect in enumerate(rects):
        is_active = (active_button == i)

        bg  = C_PRESS if is_active else C_SURFACE
        bdr = C_PRESS if is_active else C_BORDER

        draw_rounded_rect(screen, bg, rect, 10, 2, bdr)

        # Function label (top-left)
        f_col = C_ACCENT if is_active else C_MUTED
        f_txt = font_func.render(FUNC_NAMES[i], True, f_col)
        screen.blit(f_txt, (rect.x + 18, rect.y + 16))

        # Key number hint (top-right)
        k_txt = font_func.render(str(i + 1), True, C_MUTED if not is_active else (80, 110, 95))
        screen.blit(k_txt, (rect.right - 30, rect.y + 16))

        # Note name (centre)
        n_col = (255, 255, 255) if is_active else C_INK
        n_txt = font_note.render(get_note_label(i), True, n_col)
        screen.blit(
            n_txt,
            (rect.centerx - n_txt.get_width() // 2,
             rect.centery - n_txt.get_height() // 2)
        )

    pygame.display.flip()
    clock.tick(60)

pygame.quit()
