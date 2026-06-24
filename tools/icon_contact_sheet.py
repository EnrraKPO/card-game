#!/usr/bin/env python
"""Composite the rasterized icon masters onto their card-frame chips at several
sizes, so we can judge small-size legibility. Output: tools/_icon_preview/contact_sheet.png
"""
import os
from PIL import Image, ImageDraw, ImageFont

RAW = os.path.join(os.path.dirname(__file__), "_icon_preview", "raw")
OUT = os.path.join(os.path.dirname(__file__), "_icon_preview", "contact_sheet.png")

# Mirror of COMP_VISUALS in card_ui.gd  (color, text/icon color, is_element)
def c(*v): return tuple(round(x * 255) for x in v)
COMP = [
    ("fire",     c(0.86,0.28,0.16), c(1.0,0.95,0.9),  True),
    ("water",    c(0.22,0.5,0.92),  c(0.95,0.98,1.0), True),
    ("air",      c(0.62,0.83,0.93), c(0.1,0.2,0.3),   True),
    ("earth",    c(0.45,0.62,0.26), c(0.97,1.0,0.9),  True),
    ("darkness", c(0.42,0.26,0.55), c(0.95,0.9,1.0),  True),
    ("light",    c(0.95,0.84,0.34), c(0.3,0.25,0.05), True),
    ("pawn",     c(0.62,0.66,0.74), c(0.1,0.12,0.16), False),
    ("bishop",   c(0.62,0.66,0.74), c(0.1,0.12,0.16), False),
    ("knight",   c(0.62,0.66,0.74), c(0.1,0.12,0.16), False),
    ("rook",     c(0.62,0.66,0.74), c(0.1,0.12,0.16), False),
    ("queen",    c(0.85,0.72,0.35), c(0.2,0.15,0.02), False),
    ("king",     c(0.9,0.78,0.3),   c(0.2,0.15,0.02), False),
]
BORDER = (10, 10, 15, 255)
SIZES = [112, 56, 36, 24]   # inspect -> worst-case small

def raw_name(cid, is_el):
    return ("element_" if is_el else "piece_") + cid + ".png"

def tint(mask_img, color):
    out = Image.new("RGBA", mask_img.size, color + (0,))
    out.putalpha(mask_img.getchannel("A"))
    return out

def make_chip(cid, color, tcol, is_el, size):
    ss = 4
    S = size * ss
    chip = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(chip)
    bw = max(2, round(S * 0.05))
    b = bw // 2 + 1
    box = [b, b, S - b - 1, S - b - 1]
    if is_el:
        d.ellipse(box, fill=color + (255,), outline=BORDER, width=bw)
    else:
        d.rounded_rectangle(box, radius=round(S * 0.18), fill=color + (255,), outline=BORDER, width=bw)
    icon = Image.open(os.path.join(RAW, raw_name(cid, is_el))).convert("RGBA")
    isz = round(S * 0.60)
    icon = icon.resize((isz, isz), Image.LANCZOS)
    # Elements are authored full-colour (paste as-is); pieces are white
    # silhouettes tinted to the chip's text colour.
    if not is_el:
        icon = tint(icon, tcol)
    chip.alpha_composite(icon, ((S - isz) // 2, (S - isz) // 2))
    return chip.resize((size, size), Image.LANCZOS)

# --- layout ---
PAD = 18
COL_W = 150
ROW_H = 150
BG = (30, 28, 36, 255)
try:
    font = ImageFont.truetype("arial.ttf", 16)
    sfont = ImageFont.truetype("arial.ttf", 12)
except Exception:
    font = sfont = ImageFont.load_default()

cols = 6
rows = 2  # elements row, pieces row
W = PAD + cols * COL_W
H = PAD + rows * ROW_H + 40
sheet = Image.new("RGBA", (W, H), BG)
sd = ImageDraw.Draw(sheet)

for i, (cid, color, tcol, is_el) in enumerate(COMP):
    row = 0 if is_el else 1
    col = i % 6
    cx = PAD + col * COL_W
    cy = PAD + row * ROW_H + 20
    # big chip
    big = make_chip(cid, color, tcol, is_el, SIZES[0])
    sheet.alpha_composite(big, (cx, cy))
    # small chips in a row beneath
    sx = cx
    sy = cy + SIZES[0] + 6
    for s in SIZES[1:]:
        ch = make_chip(cid, color, tcol, is_el, s)
        sheet.alpha_composite(ch, (sx, sy + (SIZES[1] - s)))
        sx += s + 6
    sd.text((cx, cy - 16), cid, font=font, fill=(235, 235, 240, 255))

sd.text((PAD, H - 28), "Per icon: 112 / 56 / 36 / 24 px   (chips on the card render ~24-40px)",
        font=sfont, fill=(180, 180, 190, 255))
sheet.convert("RGB").save(OUT)
print("wrote", OUT)
