import pygame
from pythonosc import udp_client

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
QUALITIES = {
    "Major":      ["maj","min","min","maj","maj","min","dim"],
    "Minor":      ["min","dim","maj","min","min","maj","maj"],
    "Dorian":     ["min","min","maj","maj","min","dim","maj"],
    "Mixolydian": ["maj","min","dim","maj","min","min","maj"],
}
CHORD_SEMIS = {"maj":[0,4,7], "min":[0,3,7], "dim":[0,3,6]}
ROMAN = ["I","II","III","IV","V","VI"]

def pad_label(root, scale, degree):
    semi = SCALES[scale][degree]
    qual = QUALITIES[scale][degree]
    note = NOTES[(root + semi) % 12]
    suffix = "" if qual == "maj" else ("m" if qual == "min" else "°")
    roman = ROMAN[degree] if qual == "maj" else ROMAN[degree].lower()
    return roman, f"{note}{suffix}", qual

# ---------------------------------------------------------------------------
# PALETTE
# ---------------------------------------------------------------------------
C_BG      = (247, 245, 240)
C_SURFACE = (255, 255, 255)
C_BORDER  = (200, 196, 190)
C_INK     = (26, 25, 22)
C_PRESS   = (1, 24, 87)
C_MUTED   = (136, 135, 128)
C_ACCENT  = (252, 226, 28)
C_ACT_SUB = (100, 160, 130)
C_DROP_BG = (255, 255, 255)
C_DROP_HL = (236, 234, 228)

# ---------------------------------------------------------------------------
pygame.init()
info = pygame.display.Info()
W, H = info.current_w, info.current_h
screen = pygame.display.set_mode((W, H), pygame.FULLSCREEN)
pygame.display.set_caption("Chord Grid — Host")
pygame.mouse.set_visible(False)
clock = pygame.time.Clock()

font_roman = pygame.font.SysFont("Arial", 18, bold=True)
font_note  = pygame.font.SysFont("Arial", 48, bold=True)
font_qual  = pygame.font.SysFont("Arial", 15)
font_drop  = pygame.font.SysFont("Arial", 16, bold=True)
font_hint  = pygame.font.SysFont("Arial", 13)

# State
root   = 0
scale  = "Major"
active = -1

HEADER = 68
MARGIN = 16
GAP    = 8

ROOT_BTN_W   = 80
MODE_BTN_W   = 160
SIDE_GAP     = 12
PAD_CLEAR    = 16

LEFT_COL_W   = ROOT_BTN_W
RIGHT_COL_W  = MODE_BTN_W

SCALE_NAMES = list(SCALES.keys())

def pad_rects():
    grid_left  = MARGIN + LEFT_COL_W + SIDE_GAP + PAD_CLEAR
    grid_right = W - MARGIN - RIGHT_COL_W - SIDE_GAP - PAD_CLEAR
    available_w = grid_right - grid_left

    gh = H - HEADER - MARGIN
    pw = (available_w - 2 * GAP) // 3
    ph = (gh - GAP) // 2

    grid_w = 3 * pw + 2 * GAP
    start_x = grid_left + (available_w - grid_w) // 2

    rects = []
    for i in range(6):
        c, r = i % 3, i // 3
        rects.append(
            pygame.Rect(
                start_x + c * (pw + GAP),
                HEADER + r * (ph + GAP),
                pw,
                ph
            )
        )
    return rects

def root_button_rects():
    rects = []
    btn_w = ROOT_BTN_W
    btn_h = 32
    x = MARGIN
    y0 = 16
    gap_y = 2

    for i in range(len(NOTES)):
        rects.append(pygame.Rect(x, y0 + i * (btn_h + gap_y), btn_w, btn_h))
    return rects

def mode_button_rects():
    rects = []
    btn_w = MODE_BTN_W
    btn_h = 32
    x = W - MARGIN - btn_w
    y0 = 16
    gap_y = 2

    for i in range(len(SCALE_NAMES)):
        rects.append(pygame.Rect(x, y0 + i * (btn_h + gap_y), btn_w, btn_h))
    return rects

def draw_rounded_rect(surf, color, rect, radius, border=0, border_color=None):
    pygame.draw.rect(surf, color, rect, border_radius=radius)
    if border and border_color:
        pygame.draw.rect(surf, border_color, rect, border, border_radius=radius)

def select_pad(i):
    global active
    if active == i:
        active = -1
        osc_client.send_message("/chord", [NOTES[root], scale, 0])
    else:
        active = i
        osc_client.send_message("/chord", [NOTES[root], scale, i + 1])

running = True
while running:
    screen.fill(C_BG)
    rects = pad_rects()

    for event in pygame.event.get():
        if event.type == pygame.QUIT:
            running = False

        elif event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
            running = False

        elif event.type == pygame.MOUSEBUTTONDOWN or event.type == pygame.FINGERDOWN:
            clicked = False

            if event.type == pygame.MOUSEBUTTONDOWN:
                tx, ty = event.pos
            else:
                tx = int(event.x * W)
                ty = int(event.y * H)

            # Root note buttons
            for i, rect in enumerate(root_button_rects()):
                if rect.collidepoint(tx, ty):
                    root = i
                    clicked = True
                    break

            # Mode buttons
            if not clicked:
                for i, rect in enumerate(mode_button_rects()):
                    if rect.collidepoint(tx, ty):
                        scale = SCALE_NAMES[i]
                        clicked = True
                        break

            # Main pads
            if not clicked:
                for i, rect in enumerate(rects):
                    if rect.collidepoint(tx, ty):
                        select_pad(i)
                        clicked = True
                        break

        elif event.type == pygame.KEYDOWN:
            for idx, key in enumerate([
                pygame.K_1, pygame.K_2, pygame.K_3,
                pygame.K_4, pygame.K_5, pygame.K_6
            ]):
                if event.key == key:
                    select_pad(idx)

    # --- Draw root note buttons ---
    for i, rect in enumerate(root_button_rects()):
        is_active = (root == i)

        bg = C_PRESS if is_active else C_SURFACE
        bdr = C_PRESS if is_active else C_BORDER
        txt_col = (255, 255, 255) if is_active else C_INK

        draw_rounded_rect(screen, bg, rect, 6, 2, bdr)

        txt = font_drop.render(NOTES[i], True, txt_col)
        screen.blit(
            txt,
            (
                rect.centerx - txt.get_width() // 2,
                rect.centery - txt.get_height() // 2
            )
        )

    # --- Draw mode buttons ---
    for i, rect in enumerate(mode_button_rects()):
        mode_name = SCALE_NAMES[i]
        is_active = (scale == mode_name)

        bg = C_PRESS if is_active else C_SURFACE
        bdr = C_PRESS if is_active else C_BORDER
        txt_col = (255, 255, 255) if is_active else C_INK

        draw_rounded_rect(screen, bg, rect, 6, 2, bdr)

        txt = font_drop.render(mode_name, True, txt_col)
        screen.blit(
            txt,
            (
                rect.centerx - txt.get_width() // 2,
                rect.centery - txt.get_height() // 2
            )
        )

    # --- Draw pads ---
    for i, rect in enumerate(rects):
        is_active = (active == i)
        roman, note_str, qual = pad_label(root, scale, i)

        bg  = C_PRESS if is_active else C_SURFACE
        bdr = C_PRESS if is_active else C_BORDER

        draw_rounded_rect(screen, bg, rect, 10, 2, bdr)

        # Roman numeral (top-left)
        r_col = C_ACCENT if is_active else C_MUTED
        r_txt = font_roman.render(roman, True, r_col)
        screen.blit(r_txt, (rect.x + 14, rect.y + 12))

        # Key number hint (top-right)
        h_txt = font_hint.render(str(i+1), True, C_MUTED if not is_active else (80, 100, 90))
        screen.blit(h_txt, (rect.right - 20, rect.y + 12))

        # Note name (centre)
        n_col = (255, 255, 255) if is_active else C_INK
        n_txt = font_note.render(note_str, True, n_col)
        screen.blit(
            n_txt,
            (
                rect.centerx - n_txt.get_width() // 2,
                rect.centery - n_txt.get_height() // 2 + 4
            )
        )

        # Quality label (bottom-centre)
        q_col = C_ACT_SUB if is_active else C_MUTED
        q_txt = font_qual.render(qual, True, q_col)
        screen.blit(q_txt, (rect.centerx - q_txt.get_width() // 2, rect.bottom - 22))

    pygame.display.flip()
    clock.tick(60)

pygame.quit()

