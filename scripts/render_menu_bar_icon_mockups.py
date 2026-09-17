from __future__ import annotations

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


BAR_HEIGHT = 60
VOICEKEY_SLOT = (120, 0, 300, BAR_HEIGHT)
ICON_CENTER = (210, 30)
ICON_COLOR = (232, 232, 232, 255)
MUTED = (120, 120, 120, 255)
BLACK = (0, 0, 0, 255)


def font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSDisplay.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ]
    for candidate in candidates:
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, size=size)
    return ImageFont.load_default()


def rounded_line(
    draw: ImageDraw.ImageDraw,
    points: list[tuple[float, float]],
    width: int,
    fill: tuple[int, int, int, int],
) -> None:
    draw.line(points, fill=fill, width=width, joint="curve")
    radius = width / 2
    for x, y in (points[0], points[-1]):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=fill)


def draw_key_wave(draw: ImageDraw.ImageDraw, cx: int, cy: int) -> None:
    # Key bow
    draw.ellipse((cx - 22, cy - 11, cx, cy + 11), outline=ICON_COLOR, width=4)
    draw.ellipse((cx - 15, cy - 4, cx - 7, cy + 4), fill=BLACK, outline=ICON_COLOR, width=2)
    # Shaft and teeth
    rounded_line(draw, [(cx - 1, cy), (cx + 18, cy)], 4, ICON_COLOR)
    rounded_line(draw, [(cx + 10, cy), (cx + 10, cy + 7)], 4, ICON_COLOR)
    rounded_line(draw, [(cx + 17, cy), (cx + 17, cy + 5)], 4, ICON_COLOR)
    # Voice waves
    for r in (9, 15):
        draw.arc((cx + 11, cy - r, cx + 11 + r * 2, cy + r), -42, 42, fill=ICON_COLOR, width=3)


def draw_vk_mic(draw: ImageDraw.ImageDraw, cx: int, cy: int) -> None:
    rounded_line(draw, [(cx - 28, cy - 14), (cx - 18, cy + 13), (cx - 8, cy - 14)], 4, ICON_COLOR)
    rounded_line(draw, [(cx + 2, cy - 16), (cx + 2, cy + 6)], 4, ICON_COLOR)
    rounded_line(draw, [(cx + 2, cy - 1), (cx + 18, cy - 16)], 4, ICON_COLOR)
    rounded_line(draw, [(cx + 3, cy), (cx + 20, cy + 14)], 4, ICON_COLOR)
    # Mic capsule hidden in the K stem.
    draw.rounded_rectangle((cx - 2, cy - 18, cx + 8, cy + 9), radius=5, outline=ICON_COLOR, width=3)
    draw.arc((cx - 9, cy - 3, cx + 15, cy + 19), 20, 160, fill=ICON_COLOR, width=3)
    rounded_line(draw, [(cx + 3, cy + 18), (cx + 3, cy + 23)], 3, ICON_COLOR)


def draw_f16_key(draw: ImageDraw.ImageDraw, cx: int, cy: int, small_font: ImageFont.ImageFont) -> None:
    draw.rounded_rectangle((cx - 31, cy - 17, cx + 26, cy + 17), radius=7, outline=ICON_COLOR, width=3)
    text = "F16"
    box = draw.textbbox((0, 0), text, font=small_font)
    draw.text((cx - 17, cy - (box[3] - box[1]) / 2 - 1), text, font=small_font, fill=ICON_COLOR)
    draw.arc((cx + 16, cy - 9, cx + 34, cy + 9), -55, 55, fill=ICON_COLOR, width=2)
    draw.arc((cx + 20, cy - 13, cx + 44, cy + 13), -50, 50, fill=ICON_COLOR, width=2)


def draw_spark_voice(draw: ImageDraw.ImageDraw, cx: int, cy: int) -> None:
    draw.ellipse((cx - 19, cy - 19, cx + 19, cy + 19), outline=ICON_COLOR, width=3)
    draw.ellipse((cx - 5, cy - 5, cx + 5, cy + 5), fill=ICON_COLOR)
    for angle in (-35, 0, 35):
        rad = math.radians(angle)
        x0 = cx + math.cos(rad) * 11
        y0 = cy + math.sin(rad) * 11
        x1 = cx + math.cos(rad) * 19
        y1 = cy + math.sin(rad) * 19
        rounded_line(draw, [(x0, y0), (x1, y1)], 3, ICON_COLOR)
    # Small AI sparkle.
    rounded_line(draw, [(cx + 27, cy - 22), (cx + 27, cy - 10)], 2, ICON_COLOR)
    rounded_line(draw, [(cx + 21, cy - 16), (cx + 33, cy - 16)], 2, ICON_COLOR)


def draw_command_wave(draw: ImageDraw.ImageDraw, cx: int, cy: int) -> None:
    # Command-ish shortcut loops.
    for dx, dy in [(-12, -9), (12, -9), (-12, 9), (12, 9)]:
        draw.rounded_rectangle((cx + dx - 8, cy + dy - 8, cx + dx + 8, cy + dy + 8), radius=7, outline=ICON_COLOR, width=3)
    rounded_line(draw, [(cx - 12, cy), (cx + 12, cy)], 3, ICON_COLOR)
    rounded_line(draw, [(cx, cy - 9), (cx, cy + 9)], 3, ICON_COLOR)
    # Waveform accent through the middle.
    points = []
    for i in range(-24, 25, 4):
        amp = 6 + 5 * math.sin((i + 24) / 48 * math.pi)
        points.append((cx + i, cy + math.sin(i / 5) * amp))
    rounded_line(draw, points, 3, ICON_COLOR)


def clear_voicekey_slot(row: Image.Image) -> None:
    draw = ImageDraw.Draw(row)
    draw.rectangle(VOICEKEY_SLOT, fill=BLACK)


def make_sheet(screenshot_path: Path, output_path: Path) -> None:
    screenshot = Image.open(screenshot_path).convert("RGBA")
    menu_bar = screenshot.crop((0, 0, screenshot.width, BAR_HEIGHT))

    label_font = font(22)
    number_font = font(18)
    f16_font = font(19)
    row_gap = 24
    label_height = 34
    row_height = label_height + BAR_HEIGHT
    sheet_width = screenshot.width
    sheet_height = row_height * 5 + row_gap * 4 + 24
    sheet = Image.new("RGBA", (sheet_width, sheet_height), (246, 246, 246, 255))
    sheet_draw = ImageDraw.Draw(sheet)

    concepts = [
        ("1. Key + Sound Wave", draw_key_wave),
        ("2. VK Monogram as Mic", draw_vk_mic),
        ("3. F16 Function Key", lambda d, x, y: draw_f16_key(d, x, y, f16_font)),
        ("4. Spark Voice Button", draw_spark_voice),
        ("5. Command Glyph + Wave", draw_command_wave),
    ]

    y = 12
    for label, renderer in concepts:
        sheet_draw.text((24, y), label, font=label_font, fill=(34, 34, 34, 255))
        sheet_draw.text((318, y + 2), "shown replacing the current VK Ready text", font=number_font, fill=MUTED)
        row = menu_bar.copy()
        clear_voicekey_slot(row)
        row_draw = ImageDraw.Draw(row)
        renderer(row_draw, *ICON_CENTER)
        sheet.alpha_composite(row, (0, y + label_height))
        y += row_height + row_gap

    output_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.convert("RGB").save(output_path, quality=95)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: render_menu_bar_icon_mockups.py SCREENSHOT OUTPUT")
    make_sheet(Path(sys.argv[1]), Path(sys.argv[2]))
