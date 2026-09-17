from __future__ import annotations

import math
import sys
from pathlib import Path
from typing import Callable

from PIL import Image, ImageDraw, ImageFont


BAR_HEIGHT = 60
SOURCE_CROP = (120, 0, 550, BAR_HEIGHT)
VOICEKEY_CLEAR = (0, 0, 174, BAR_HEIGHT)
ICON_CENTER = (90, 30)

BLACK = (0, 0, 0, 255)
PAPER = (246, 246, 246, 255)
INK = (32, 32, 32, 255)
SUBTLE = (116, 116, 116, 255)
WHITE = (235, 235, 235, 255)
SOFT = (180, 180, 180, 255)
DIM = (126, 126, 126, 255)
ALERT = (255, 88, 82, 255)


StateRenderer = Callable[[ImageDraw.ImageDraw, int, int, float, str], None]


def font(size: int, *, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = (
        "/System/Library/Fonts/Supplemental/Futura.ttc",
        "/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf",
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
    )
    for candidate in candidates:
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, size=size)
    return ImageFont.load_default()


def rounded(draw: ImageDraw.ImageDraw, box, radius: int, fill, outline=None, width: int = 1) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def centered_text(
    draw: ImageDraw.ImageDraw,
    box: tuple[int, int, int, int],
    text: str,
    text_font: ImageFont.ImageFont,
    fill,
    y_adjust: int = 0,
) -> None:
    left, top, right, bottom = box
    text_box = draw.textbbox((0, 0), text, font=text_font)
    width = text_box[2] - text_box[0]
    height = text_box[3] - text_box[1]
    x = left + (right - left - width) / 2 - text_box[0]
    y = top + (bottom - top - height) / 2 - text_box[1] + y_adjust
    draw.text((x, y), text, font=text_font, fill=fill)


def bubble_path_box(cx: int, cy: int, scale: float) -> tuple[int, int, int, int]:
    width = round(40 * scale)
    height = round(28 * scale)
    return (cx - width // 2, cy - height // 2 - round(1 * scale), cx + width // 2, cy + height // 2 - round(1 * scale))


def draw_tail(draw: ImageDraw.ImageDraw, cx: int, cy: int, scale: float, fill) -> None:
    x = cx - round(9 * scale)
    y = cy + round(11 * scale)
    draw.polygon(
        [
            (x, y - round(1 * scale)),
            (x + round(6 * scale), y - round(1 * scale)),
            (x + round(2 * scale), y + round(7 * scale)),
        ],
        fill=fill,
    )


def draw_status_bubble(draw: ImageDraw.ImageDraw, cx: int, cy: int, scale: float, state: str) -> None:
    box = bubble_path_box(cx, cy, scale)
    radius = round(9 * scale)
    if state == "loading":
        rounded(draw, box, radius, None, SOFT, max(1, round(2.2 * scale)))
        draw_tail(draw, cx, cy, scale, SOFT)
        centered_text(draw, box, "F16", font(round(12 * scale), bold=True), SOFT, y_adjust=round(1 * scale))
        ring = (box[0] - round(6 * scale), box[1] - round(5 * scale), box[0] + round(9 * scale), box[1] + round(10 * scale))
        draw.arc(ring, 210, 540, fill=WHITE, width=max(1, round(2 * scale)))
        draw.ellipse((ring[2] - round(3 * scale), ring[1], ring[2], ring[1] + round(3 * scale)), fill=WHITE)
    elif state == "ready":
        rounded(draw, box, radius, WHITE)
        draw_tail(draw, cx, cy, scale, WHITE)
        centered_text(draw, box, "F16", font(round(13 * scale), bold=True), BLACK, y_adjust=round(1 * scale))
    elif state == "active":
        rounded(draw, box, radius, WHITE)
        draw_tail(draw, cx, cy, scale, WHITE)
        centered_text(draw, box, "F16", font(round(13 * scale), bold=True), BLACK, y_adjust=round(1 * scale))
        mic_box = (
            box[2] - round(11 * scale),
            cy - round(8 * scale),
            box[2] - round(3 * scale),
            cy + round(8 * scale),
        )
        draw.rounded_rectangle(mic_box, radius=round(4 * scale), fill=BLACK)
        for index, height in enumerate((5, 10, 15)):
            x = box[2] + round((4 + index * 5) * scale)
            draw.line(
                (x, cy - round(height * scale / 2), x, cy + round(height * scale / 2)),
                fill=WHITE,
                width=max(1, round(1.8 * scale)),
            )
    else:
        rounded(draw, box, radius, WHITE)
        draw_tail(draw, cx, cy, scale, WHITE)
        centered_text(draw, box, "F16", font(round(13 * scale), bold=True), BLACK, y_adjust=round(1 * scale))
        badge_r = round(7 * scale)
        bx = box[2] - round(1 * scale)
        by = box[1] + round(2 * scale)
        draw.ellipse((bx - badge_r, by - badge_r, bx + badge_r, by + badge_r), fill=ALERT)
        centered_text(draw, (bx - badge_r, by - badge_r - 1, bx + badge_r, by + badge_r), "!", font(round(12 * scale), bold=True), WHITE)


def draw_f16_tile(draw: ImageDraw.ImageDraw, cx: int, cy: int, scale: float, state: str) -> None:
    tile = (
        cx - round(21 * scale),
        cy - round(15 * scale),
        cx + round(21 * scale),
        cy + round(15 * scale),
    )
    radius = round(8 * scale)
    if state == "loading":
        rounded(draw, tile, radius, None, SOFT, max(1, round(2 * scale)))
        centered_text(draw, tile, "F16", font(round(12 * scale), bold=True), SOFT, y_adjust=round(1 * scale))
        for i in range(7):
            angle = i / 7 * math.tau
            alpha = 90 + i * 22
            x = cx + math.cos(angle) * round(26 * scale)
            y = cy + math.sin(angle) * round(18 * scale)
            dot = max(1, round(1.6 * scale))
            draw.ellipse((x - dot, y - dot, x + dot, y + dot), fill=(235, 235, 235, min(255, alpha)))
    elif state == "ready":
        rounded(draw, tile, radius, WHITE)
        centered_text(draw, tile, "F16", font(round(13 * scale), bold=True), BLACK, y_adjust=round(1 * scale))
    elif state == "active":
        rounded(draw, tile, radius, WHITE)
        centered_text(draw, tile, "F16", font(round(13 * scale), bold=True), BLACK, y_adjust=round(1 * scale))
        outer = (
            tile[0] - round(5 * scale),
            tile[1] - round(5 * scale),
            tile[2] + round(5 * scale),
            tile[3] + round(5 * scale),
        )
        draw.rounded_rectangle(outer, radius=round(12 * scale), outline=WHITE, width=max(1, round(1.7 * scale)))
    else:
        rounded(draw, tile, radius, WHITE)
        centered_text(draw, tile, "F16", font(round(13 * scale), bold=True), BLACK, y_adjust=round(1 * scale))
        diamond = [
            (tile[2] + round(3 * scale), cy),
            (tile[2] + round(10 * scale), cy - round(7 * scale)),
            (tile[2] + round(17 * scale), cy),
            (tile[2] + round(10 * scale), cy + round(7 * scale)),
        ]
        draw.polygon(diamond, fill=ALERT)
        centered_text(draw, (tile[2] + round(3 * scale), cy - round(7 * scale), tile[2] + round(17 * scale), cy + round(7 * scale)), "!", font(round(10 * scale), bold=True), WHITE)


def draw_voice_panel(draw: ImageDraw.ImageDraw, cx: int, cy: int, scale: float, state: str) -> None:
    bubble = bubble_path_box(cx, cy, scale)
    radius = round(10 * scale)
    rounded(draw, bubble, radius, WHITE)
    draw_tail(draw, cx, cy, scale, WHITE)

    if state == "loading":
        dot_r = round(2.4 * scale)
        for index, alpha in enumerate((125, 190, 255)):
            x = cx - round(7 * scale) + index * round(7 * scale)
            draw.ellipse((x - dot_r, cy - dot_r, x + dot_r, cy + dot_r), fill=(0, 0, 0, alpha))
        key = (bubble[2] - round(16 * scale), bubble[3] - round(10 * scale), bubble[2] + round(4 * scale), bubble[3] + round(4 * scale))
        rounded(draw, key, round(3 * scale), BLACK)
        centered_text(draw, key, "F16", font(round(5.8 * scale), bold=True), WHITE)
    elif state == "ready":
        centered_text(draw, bubble, "F16", font(round(13 * scale), bold=True), BLACK, y_adjust=round(1 * scale))
    elif state == "active":
        bars = (5, 12, 20, 13, 7)
        x0 = cx - round(13 * scale)
        for index, height in enumerate(bars):
            x = x0 + index * round(6 * scale)
            draw.rounded_rectangle(
                (x, cy - round(height * scale / 2), x + round(2.5 * scale), cy + round(height * scale / 2)),
                radius=round(1.5 * scale),
                fill=BLACK,
            )
        key = (bubble[0] + round(4 * scale), bubble[1] + round(3 * scale), bubble[0] + round(22 * scale), bubble[1] + round(12 * scale))
        rounded(draw, key, round(3 * scale), BLACK)
        centered_text(draw, key, "F16", font(round(5.2 * scale), bold=True), WHITE)
    else:
        centered_text(draw, bubble, "F16", font(round(12 * scale), bold=True), BLACK, y_adjust=round(1 * scale))
        badge_r = round(7 * scale)
        bx = bubble[2] - round(1 * scale)
        by = bubble[1] + round(2 * scale)
        draw.ellipse((bx - badge_r, by - badge_r, bx + badge_r, by + badge_r), fill=ALERT)
        centered_text(draw, (bx - badge_r, by - badge_r - 1, bx + badge_r, by + badge_r), "!", font(round(12 * scale), bold=True), WHITE)


def render_icon(renderer: StateRenderer, state: str, scale: float = 2.8) -> Image.Image:
    canvas = Image.new("RGBA", (220, 112), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    renderer(draw, 92, 56, scale, state)
    return canvas


def paste_icon(row: Image.Image, renderer: StateRenderer, state: str) -> None:
    icon = render_icon(renderer, state, 2.75)
    alpha = icon.getchannel("A")
    box = alpha.getbbox()
    if box:
        icon = icon.crop(box)
    icon.thumbnail((58, 38), Image.Resampling.LANCZOS)
    row.alpha_composite(icon, (ICON_CENTER[0] - icon.width // 2, ICON_CENTER[1] - icon.height // 2))


def make_cell(menu_crop: Image.Image, renderer: StateRenderer, state: str) -> Image.Image:
    cell = Image.new("RGBA", (430, 60), BLACK)
    cell.alpha_composite(menu_crop)
    draw = ImageDraw.Draw(cell)
    draw.rectangle(VOICEKEY_CLEAR, fill=BLACK)
    paste_icon(cell, renderer, state)
    return cell


def make_zoom(renderer: StateRenderer, state: str) -> Image.Image:
    panel = Image.new("RGBA", (94, 76), BLACK)
    icon = render_icon(renderer, state, 3.9)
    alpha = icon.getchannel("A")
    box = alpha.getbbox()
    if box:
        icon = icon.crop(box)
    icon.thumbnail((78, 56), Image.Resampling.LANCZOS)
    panel.alpha_composite(icon, ((panel.width - icon.width) // 2, (panel.height - icon.height) // 2))
    return panel


def make_mockup(screenshot_path: Path, output_path: Path) -> None:
    screenshot = Image.open(screenshot_path).convert("RGBA")
    menu_crop = screenshot.crop(SOURCE_CROP)

    states = [
        ("Loading", "loading"),
        ("Ready", "ready"),
        ("Active", "active"),
        ("Error", "error"),
    ]
    versions: list[tuple[str, str, StateRenderer]] = [
        ("A", "F16 speech bubble", draw_status_bubble),
        ("B", "F16 key tile", draw_f16_tile),
        ("C", "Voice bubble", draw_voice_panel),
    ]

    sheet_w = 1428
    sheet_h = 732
    sheet = Image.new("RGBA", (sheet_w, sheet_h), PAPER)
    draw = ImageDraw.Draw(sheet)

    title = font(27, bold=True)
    label = font(17)
    small = font(14)

    draw.text((24, 20), "VoiceKey menu bar states", font=title, fill=INK)
    draw.text((24, 56), "Three visual systems, four states each, shown at real menu-bar scale in your current layout.", font=label, fill=SUBTLE)

    left = 104
    cell_w = 430
    gutter = 14
    top = 128
    row_h = 92

    for col, (code, name, _) in enumerate(versions):
        x = left + col * (cell_w + gutter)
        draw.text((x, 104), f"{code}. {name}", font=label, fill=INK)

    for row_index, (state_label, state) in enumerate(states):
        y = top + row_index * row_h
        draw.text((24, y + 19), state_label, font=label, fill=INK)
        for col, (_, _, renderer) in enumerate(versions):
            x = left + col * (cell_w + gutter)
            cell = make_cell(menu_crop, renderer, state)
            sheet.alpha_composite(cell, (x, y))
            draw.rounded_rectangle((x, y, x + cell_w, y + 60), radius=1, outline=(226, 226, 226, 255), width=1)

    zoom_y = 548
    draw.text((24, zoom_y - 34), "Zoomed detail", font=label, fill=INK)
    for col, (code, name, renderer) in enumerate(versions):
        base_x = 188 + col * 404
        draw.text((base_x, zoom_y - 28), f"{code}. {name}", font=small, fill=SUBTLE)
        for idx, (state_label, state) in enumerate(states):
            x = base_x + idx * 96
            zoom = make_zoom(renderer, state)
            sheet.alpha_composite(zoom, (x, zoom_y))
            text_box = draw.textbbox((0, 0), state_label, font=small)
            tw = text_box[2] - text_box[0]
            draw.text((x + (94 - tw) / 2, zoom_y + 82), state_label, font=small, fill=SUBTLE)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.convert("RGB").save(output_path, quality=95)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: render_voicekey_state_icon_mockups.py SCREENSHOT OUTPUT")
    make_mockup(Path(sys.argv[1]), Path(sys.argv[2]))
