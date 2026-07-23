from __future__ import annotations

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


WHITE = (255, 255, 255, 255)
BLACK = (0, 0, 0, 255)


def font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(path, size=size, index=index)


def text_size(draw: ImageDraw.ImageDraw, text: str, fnt: ImageFont.ImageFont) -> tuple[int, int]:
    box = draw.textbbox((0, 0), text, font=fnt)
    return box[2] - box[0], box[3] - box[1]


def glow_text(
    base: Image.Image,
    xy: tuple[int, int],
    text: str,
    fnt: ImageFont.ImageFont,
    fill: tuple[int, int, int, int] = WHITE,
    glow: tuple[int, int, int, int] = (0, 190, 255, 150),
    radius: int = 14,
) -> None:
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.text(xy, text, font=fnt, fill=glow)
    blur = layer.filter(ImageFilter.GaussianBlur(radius))
    base.alpha_composite(blur)
    draw = ImageDraw.Draw(base)
    draw.text(xy, text, font=fnt, fill=fill)


def draw_speech_mark(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], fill=WHITE) -> None:
    x0, y0, x1, y1 = box
    draw.rounded_rectangle((x0, y0, x1, y1), radius=(y1 - y0) // 2, fill=fill)
    tail = [(x0 + 20, y1 - 3), (x0 + 32, y1 + 16), (x0 + 48, y1 - 4)]
    draw.polygon(tail, fill=fill)
    # Simple AI sparkle knockout.
    cx = x0 + 46
    cy = (y0 + y1) // 2
    draw.rounded_rectangle((cx - 4, cy - 18, cx + 4, cy + 18), radius=3, fill=BLACK)
    draw.rounded_rectangle((cx - 18, cy - 4, cx + 18, cy + 4), radius=3, fill=BLACK)


def version_futura_hero(src: Image.Image, out: Path) -> None:
    image = src.copy()
    draw = ImageDraw.Draw(image)
    title_font = font("/System/Library/Fonts/Supplemental/Futura.ttc", 102)
    subtitle_font = font("/System/Library/Fonts/Avenir Next.ttc", 29)

    x, y = 94, 92
    glow_text(image, (x, y), "VoiceKey", title_font, radius=18)
    draw.text((x + 6, y + 114), "tap a key. start talking.", font=subtitle_font, fill=(228, 244, 255, 230))
    out.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(out, quality=96)


def version_glass_pill(src: Image.Image, out: Path) -> None:
    image = src.copy()
    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    title_font = font("/System/Library/Fonts/Avenir Next.ttc", 78)

    pill = (80, 76, 568, 180)
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle((pill[0] + 6, pill[1] + 8, pill[2] + 6, pill[3] + 8), radius=52, fill=(0, 0, 0, 110))
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(12)))

    draw.rounded_rectangle(pill, radius=52, fill=(255, 255, 255, 42), outline=(255, 255, 255, 130), width=2)
    draw_speech_mark(draw, (112, 104, 174, 154), fill=WHITE)
    overlay = overlay.filter(ImageFilter.GaussianBlur(0.15))
    image.alpha_composite(overlay)

    glow_text(image, (196, 82), "VoiceKey", title_font, fill=WHITE, glow=(210, 90, 255, 110), radius=10)
    image.convert("RGB").save(out, quality=96)


def gradient_text_layer(size: tuple[int, int], text: str, fnt: ImageFont.ImageFont, xy: tuple[int, int]) -> Image.Image:
    mask = Image.new("L", size, 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.text(xy, text, font=fnt, fill=255)
    gradient = Image.new("RGBA", size, (0, 0, 0, 0))
    pixels = gradient.load()
    width, height = size
    for x in range(width):
        t = x / max(width - 1, 1)
        r = int(255 * (1 - t) + 130 * t)
        g = int(255 * (1 - abs(t - 0.45) * 1.5))
        b = int(255 * t + 255 * (1 - t) * 0.35)
        for y in range(height):
            pixels[x, y] = (r, max(90, min(g, 255)), b, 255)
    gradient.putalpha(mask)
    return gradient


def version_cosmic_wordmark(src: Image.Image, out: Path) -> None:
    image = src.copy()
    draw = ImageDraw.Draw(image)
    title_font = font("/System/Library/Fonts/Avenir Next.ttc", 92)
    subtitle_font = font("/System/Library/Fonts/Avenir Next.ttc", 28)

    x, y = 88, 88
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.text((x, y), "VoiceKey", font=title_font, fill=(0, 0, 0, 190))
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(9)))
    image.alpha_composite(gradient_text_layer(image.size, "VoiceKey", title_font, (x, y)))

    # Tiny orbit/spark accent over the i to make the mark feel more ownable.
    dot_x = x + 292
    dot_y = y + 18
    for radius, alpha in ((24, 80), (15, 130)):
        draw.ellipse((dot_x - radius, dot_y - radius, dot_x + radius, dot_y + radius), outline=(130, 230, 255, alpha), width=3)
    draw.ellipse((dot_x - 5, dot_y - 5, dot_x + 5, dot_y + 5), fill=WHITE)
    draw.text((x + 4, y + 108), "one key to voice AI", font=subtitle_font, fill=(237, 245, 255, 225))

    image.convert("RGB").save(out, quality=96)


def make_versions(src_path: Path, out_dir: Path) -> None:
    src = Image.open(src_path).convert("RGBA")
    version_futura_hero(src, out_dir / "voicekey-promo-shrimp-closeup-logotype-futura.png")
    version_glass_pill(src, out_dir / "voicekey-promo-shrimp-closeup-logotype-pill.png")
    version_cosmic_wordmark(src, out_dir / "voicekey-promo-shrimp-closeup-logotype-cosmic.png")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: render_voicekey_promo_logotypes.py SOURCE_IMAGE OUTPUT_DIR")
    make_versions(Path(sys.argv[1]), Path(sys.argv[2]))
