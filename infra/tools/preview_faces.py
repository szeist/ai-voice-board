# /// script
# dependencies = ["pillow"]
# ///
"""Preview infra/faces/*.png as the patched OLED firmware (oled-faces.patch) shows them.

Reproduces the board's pipeline for the 128x64 SSD1306:
  - LVGL (RGB565, light default theme) draws the image over the white background,
    in the 32 px face column, centered, 8 px below the 16 px status bar.
  - esp_lvgl_port turns each pixel on/off: lit if blue (5-bit) <= 16, i.e. dark = lit.
  - Emotions without an image fall back to the built-in 1-bit emoji font.

  uv run infra/tools/preview_faces.py <faces dir> <xiaozhi-fonts component dir> <out.png>
"""
import os
import re
import sys

from PIL import Image, ImageDraw

faces_dir, fonts_dir, out_path = sys.argv[1:4]
COLUMN_W, TOP_BAR, PAD_TOP = 32, 16, 8  # oled_display.cc SetupUI_128x64


def lit(rgb):
    """esp_lvgl_port _lvgl_port_transform_monochrome: off if RGB565 blue > 16."""
    return (rgb[2] >> 3) <= 16


def render_image(path):
    """PNG over white, as LVGL composes it, then the panel's on/off rule."""
    img = Image.open(path).convert("RGBA")
    white = Image.new("RGBA", img.size, (255, 255, 255, 255))
    rgb = Image.alpha_composite(white, img).convert("RGB")
    out = Image.new("1", img.size, 0)
    for y in range(img.height):
        for x in range(img.width):
            out.putpixel((x, y), 1 if lit(rgb.getpixel((x, y))) else 0)
    return out


def load_font():
    """Built-in fallback: font_noto_emoji_30_1 (LVGL 1-bpp) and emotion -> codepoint."""
    c = open(os.path.join(fonts_dir, "src/font_noto_emoji_30_1.c")).read()
    bitmap = bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{1,2})\b",
                   c[c.index("glyph_bitmap[]"):c.index("glyph_dsc[]")]))
    dsc = [list(map(int, m)) for m in re.findall(
        r"\.bitmap_index = (\d+), \.adv_w = \d+, \.box_w = (\d+), \.box_h = (\d+), "
        r"\.ofs_x = (-?\d+), \.ofs_y = (-?\d+)", c)]
    start = int(re.search(r"\.range_start = (\d+)", c).group(1))
    offsets = [int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]+)",
               c[c.index("unicode_list_0[]"):c.index("cmaps[]")])]
    glyph_of = {start + o: i + 1 for i, o in enumerate(offsets)}
    header = open(os.path.join(fonts_dir, "include/noto_emoji.h")).read()
    emotions = {}
    for name, esc in re.findall(r'#define NOTO_EMOJI_([A-Z_]+) "([^"]+)"', header):
        cp = ord(bytes(int(b, 16) for b in re.findall(r"\\x([0-9a-f]{2})", esc)).decode())
        emotions[name.lower()] = cp

    def glyph(name):
        idx, w, h, ox, oy = dsc[glyph_of[emotions[name]]]
        img = Image.new("1", (38, 32), 0)  # advance 609/16 px, line height 32, baseline 6
        for y in range(h):
            for x in range(w):
                bit = y * w + x
                if bitmap[idx + bit // 8] >> (7 - bit % 8) & 1:
                    img.putpixel((x + ox, 32 - 6 - oy - h + y), 1)
        return img

    return list(emotions), glyph


def screen_with(face):
    """128x64 frame with the face placed and clipped like the 32 px column."""
    screen = Image.new("1", (128, 64), 0)
    col = Image.new("1", (COLUMN_W, 64 - TOP_BAR), 0)
    col.paste(face, ((COLUMN_W - face.width) // 2, PAD_TOP))
    screen.paste(col, (0, TOP_BAR))
    return screen


def oled(img, scale, on=(80, 200, 255), off=(8, 10, 14)):
    out = Image.new("RGB", (img.width * scale, img.height * scale), (0, 0, 0))
    d = ImageDraw.Draw(out)
    for y in range(img.height):
        for x in range(img.width):
            d.rectangle([x * scale, y * scale, x * scale + scale - 2, y * scale + scale - 2],
                        fill=on if img.getpixel((x, y)) else off)
    return out


names, glyph = load_font()
faces = {}
for name in names:
    path = os.path.join(faces_dir, f"{name}.png")
    if os.path.exists(path):
        faces[name] = (render_image(path), "image")
    else:
        faces[name] = (glyph(name), "font (no image)")

# Sheet: the face area of the screen (32 px column, below the status bar) per emotion
cols, scale = 7, 4
cw, ch = COLUMN_W * scale, (64 - TOP_BAR) * scale
rows = (len(names) + cols - 1) // cols
sheet = Image.new("RGB", (16 + cols * (cw + 24), 16 + rows * (ch + 44)), (30, 30, 30))
d = ImageDraw.Draw(sheet)
for i, name in enumerate(names):
    face, source = faces[name]
    x, y = 16 + (i % cols) * (cw + 24), 16 + (i // cols) * (ch + 44)
    crop = screen_with(face).crop((0, TOP_BAR, COLUMN_W, 64))
    sheet.paste(oled(crop, scale), (x, y))
    d.text((x, y + ch + 6), name, fill=(230, 230, 230))
    d.text((x, y + ch + 20), source, fill=(150, 150, 150) if source == "image" else (230, 170, 80))

# Full screen with the neutral face (status bar and text omitted: they depend on state)
full = oled(screen_with(faces["neutral"][0]), 4)
result = Image.new("RGB", (max(sheet.width, full.width + 32), sheet.height + full.height + 40), (30, 30, 30))
result.paste(sheet, (0, 0))
ImageDraw.Draw(result).text((16, sheet.height + 8), "Whole 128x64 screen, neutral face (status bar and text not drawn):", fill=(230, 230, 230))
result.paste(full, (16, sheet.height + 28))
result.save(out_path)
print(f"{sum(s == 'image' for _, s in faces.values())} images, "
      f"{sum(s != 'image' for _, s in faces.values())} font fallbacks -> {out_path}")
