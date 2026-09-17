from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


BAR_HEIGHT = 60
VOICEKEY_SLOT = (120, 0, 300, BAR_HEIGHT)
BLACK = (0, 0, 0, 255)
GRAY = (118, 118, 118, 255)


def font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for candidate in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSDisplay.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ):
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, size=size)
    return ImageFont.load_default()


def crop_icon(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    width, height = rgba.size
    xs: list[int] = []
    ys: list[int] = []
    for y in range(height):
        for x in range(width):
            r, g, b, _ = pixels[x, y]
            if r + g + b > 90:
                xs.append(x)
                ys.append(y)
    if not xs:
        return rgba
    pad = 24
    return rgba.crop(
        (
            max(min(xs) - pad, 0),
            max(min(ys) - pad, 0),
            min(max(xs) + pad, width),
            min(max(ys) + pad, height),
        )
    )


def paste_scaled_icon(row: Image.Image, icon: Image.Image, max_width: int, max_height: int) -> None:
    cropped = crop_icon(icon)
    cropped.thumbnail((max_width, max_height), Image.Resampling.LANCZOS)
    # Treat near-black background as transparent, preserving black F16 knockout by
    # compositing onto the black menu bar first.
    icon_layer = Image.new("RGBA", cropped.size, BLACK)
    icon_layer.alpha_composite(cropped)
    x = 210 - icon_layer.width // 2
    y = 30 - icon_layer.height // 2
    row.alpha_composite(icon_layer, (x, y))


def make_mockup(screenshot_path: Path, generated_icon_path: Path, output_path: Path) -> None:
    screenshot = Image.open(screenshot_path).convert("RGBA")
    generated = Image.open(generated_icon_path).convert("RGBA")
    menu_bar = screenshot.crop((0, 0, screenshot.width, BAR_HEIGHT))

    sheet = Image.new("RGBA", (screenshot.width, 392), (246, 246, 246, 255))
    draw = ImageDraw.Draw(sheet)
    title_font = font(24)
    label_font = font(18)

    draw.text((24, 18), "GPT-rendered F16 speech bubble", font=title_font, fill=(32, 32, 32, 255))
    draw.text((24, 50), "Two real-size menu-bar scalings", font=label_font, fill=GRAY)

    for idx, (label, max_size) in enumerate((("A. Compact, same footprint as neighboring menu icons", 29), ("B. Larger, prioritizes F16 readability", 36))):
        y = 102 + idx * 96
        draw.text((24, y - 24), label, font=label_font, fill=(42, 42, 42, 255))
        row = menu_bar.copy()
        row_draw = ImageDraw.Draw(row)
        row_draw.rectangle(VOICEKEY_SLOT, fill=BLACK)
        paste_scaled_icon(row, generated, max_size, max_size)
        sheet.alpha_composite(row, (0, y))

    draw.text((24, 292), "Generated source", font=label_font, fill=GRAY)
    source = crop_icon(generated)
    source.thumbnail((120, 80), Image.Resampling.LANCZOS)
    source_back = Image.new("RGBA", (150, 92), BLACK)
    source_back.alpha_composite(source, ((150 - source.width) // 2, (92 - source.height) // 2))
    sheet.alpha_composite(source_back, (24, 316))

    note_font = font(16)
    draw.text((198, 334), "This keeps the white bubble and black knockout text from the GPT render.", font=note_font, fill=(55, 55, 55, 255))
    draw.text((198, 358), "B is probably the better menu-bar tradeoff; A is cleaner but the F16 gets small.", font=note_font, fill=(55, 55, 55, 255))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.convert("RGB").save(output_path, quality=95)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: render_generated_icon_in_menu_bar.py SCREENSHOT GENERATED_ICON OUTPUT")
    make_mockup(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
