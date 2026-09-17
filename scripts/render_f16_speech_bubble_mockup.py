from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


BAR_HEIGHT = 60
VOICEKEY_SLOT = (120, 0, 300, BAR_HEIGHT)
BLACK = (0, 0, 0, 255)
WHITE = (232, 232, 232, 255)
GRAY = (118, 118, 118, 255)


PIXEL_FONT = {
    "F": ["111", "100", "110", "100", "100"],
    "1": ["010", "110", "010", "010", "111"],
    "6": ["111", "100", "111", "101", "111"],
}


def font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for candidate in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSDisplay.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ):
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, size=size)
    return ImageFont.load_default()


def pixel_text(draw: ImageDraw.ImageDraw, text: str, x: int, y: int, scale: int, fill) -> None:
    cursor = x
    for char in text:
        glyph = PIXEL_FONT[char]
        for row_index, row in enumerate(glyph):
            for column_index, bit in enumerate(row):
                if bit == "1":
                    x0 = cursor + column_index * scale
                    y0 = y + row_index * scale
                    draw.rectangle((x0, y0, x0 + scale - 1, y0 + scale - 1), fill=fill)
        cursor += (len(glyph[0]) + 1) * scale


def draw_bubble_icon(
    draw: ImageDraw.ImageDraw,
    cx: int,
    cy: int,
    scale: int = 2,
    bubble_fill=WHITE,
    cutout_fill=BLACK,
    mode: str = "filled_cutout",
) -> None:
    # Deliberately blocky: 16-bit style speech bubble in a 42x30 px footprint.
    left = cx - 21
    top = cy - 15
    unit = scale

    # Outer bubble, assembled from rectangles to keep square corners.
    draw.rectangle((left + 4 * unit, top, left + 17 * unit, top + 2 * unit), fill=bubble_fill)
    draw.rectangle((left + 2 * unit, top + 2 * unit, left + 19 * unit, top + 4 * unit), fill=bubble_fill)
    draw.rectangle((left, top + 4 * unit, left + 21 * unit, top + 11 * unit), fill=bubble_fill)
    draw.rectangle((left + 2 * unit, top + 11 * unit, left + 17 * unit, top + 13 * unit), fill=bubble_fill)
    draw.rectangle((left + 6 * unit, top + 13 * unit, left + 11 * unit, top + 14 * unit), fill=bubble_fill)
    draw.rectangle((left + 8 * unit, top + 15 * unit, left + 12 * unit, top + 16 * unit), fill=bubble_fill)

    if mode == "filled_text":
        pixel_text(draw, "F16", left + 4 * unit, top + 5 * unit, scale=unit, fill=cutout_fill)
        return

    # Interior cutout.
    draw.rectangle((left + 3 * unit, top + 4 * unit, left + 18 * unit, top + 10 * unit), fill=cutout_fill)
    draw.rectangle((left + 5 * unit, top + 2 * unit, left + 16 * unit, top + 3 * unit), fill=cutout_fill)

    # Pixel F16 text inside the negative space.
    pixel_text(draw, "F16", left + 4 * unit, top + 5 * unit, scale=unit, fill=bubble_fill)


def draw_bubble_outline(draw: ImageDraw.ImageDraw, cx: int, cy: int, scale: int = 2) -> None:
    left = cx - 24
    top = cy - 16
    unit = scale
    # Chunky outline-only bubble, closer to a template SF Symbol but still pixel-edged.
    blocks = [
        (3, 0, 19, 1),
        (1, 1, 3, 3),
        (19, 1, 21, 3),
        (0, 3, 2, 12),
        (20, 3, 22, 12),
        (2, 12, 16, 14),
        (6, 14, 11, 16),
        (8, 16, 13, 18),
        (16, 11, 20, 13),
    ]
    for x0, y0, x1, y1 in blocks:
        draw.rectangle(
            (left + x0 * unit, top + y0 * unit, left + x1 * unit, top + y1 * unit),
            fill=WHITE,
        )
    pixel_text(draw, "F16", left + 5 * unit, top + 6 * unit, scale=unit, fill=WHITE)


def make_mockup(screenshot_path: Path, output_path: Path) -> None:
    screenshot = Image.open(screenshot_path).convert("RGBA")
    menu_bar = screenshot.crop((0, 0, screenshot.width, BAR_HEIGHT))
    sheet_width = screenshot.width
    row_height = BAR_HEIGHT
    label_height = 30
    gap = 18
    sheet_height = 486
    sheet = Image.new("RGBA", (sheet_width, sheet_height), (246, 246, 246, 255))
    draw = ImageDraw.Draw(sheet)
    title_font = font(24)
    label_font = font(18)

    draw.text((24, 18), "F16 Speech Bubble - pixel menu-bar mockup", font=title_font, fill=(32, 32, 32, 255))
    draw.text((24, 50), "Real size in your current menu bar, replacing VK Ready", font=label_font, fill=GRAY)

    variants = [
        ("A. Filled bubble with cutout F16", lambda d: draw_bubble_icon(d, 210, 30, scale=2, mode="filled_cutout")),
        ("B. Filled bubble with dark pixel F16", lambda d: draw_bubble_icon(d, 210, 30, scale=2, mode="filled_text")),
        ("C. Outline bubble with white F16", lambda d: draw_bubble_outline(d, 210, 30, scale=2)),
    ]

    y = 104
    for label, renderer in variants:
        draw.text((24, y - 24), label, font=label_font, fill=(42, 42, 42, 255))
        row = menu_bar.copy()
        row_draw = ImageDraw.Draw(row)
        row_draw.rectangle(VOICEKEY_SLOT, fill=BLACK)
        renderer(row_draw)
        sheet.alpha_composite(row, (0, y))
        y += row_height + label_height + gap

    draw.text((24, 394), "Zoomed detail of A", font=label_font, fill=GRAY)
    detail = Image.new("RGBA", (150, 78), BLACK)
    detail_draw = ImageDraw.Draw(detail)
    draw_bubble_icon(detail_draw, 75, 32, scale=4, mode="filled_cutout")
    sheet.alpha_composite(detail, (24, 418))

    note_font = font(16)
    draw.text((198, 434), "A is the most template-icon-friendly: one white silhouette with transparent cutouts.", font=note_font, fill=(55, 55, 55, 255))
    draw.text((198, 458), "B reads F16 fastest, but relies on dark interior detail.", font=note_font, fill=(55, 55, 55, 255))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.convert("RGB").save(output_path, quality=95)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: render_f16_speech_bubble_mockup.py SCREENSHOT OUTPUT")
    make_mockup(Path(sys.argv[1]), Path(sys.argv[2]))
