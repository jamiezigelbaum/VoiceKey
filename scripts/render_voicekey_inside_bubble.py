from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


INK = (66, 38, 98, 255)
ACCENT = (0, 178, 214, 210)
WARM = (238, 123, 72, 230)


def font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(path, size=size, index=index)


def centered_text(
    draw: ImageDraw.ImageDraw,
    center_x: int,
    y: int,
    text: str,
    fnt: ImageFont.ImageFont,
    fill,
    stroke_width: int = 0,
    stroke_fill=None,
) -> tuple[int, int, int, int]:
    box = draw.textbbox((0, 0), text, font=fnt, stroke_width=stroke_width)
    width = box[2] - box[0]
    x = center_x - width // 2
    draw.text(
        (x, y),
        text,
        font=fnt,
        fill=fill,
        stroke_width=stroke_width,
        stroke_fill=stroke_fill,
    )
    return (x, y, x + width, y + (box[3] - box[1]))


def clean_bubble(image: Image.Image) -> None:
    # The prompt image already has a beautiful glossy bubble. This masks only
    # the inner mark area so the outer rim, tail, glow, and lighting survive.
    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.rounded_rectangle((856, 172, 1130, 412), radius=80, fill=(248, 252, 255, 248))
    draw.ellipse((844, 144, 1168, 444), fill=(248, 252, 255, 244))
    overlay = overlay.filter(ImageFilter.GaussianBlur(5))
    image.alpha_composite(overlay)


def draw_flourish(draw: ImageDraw.ImageDraw, x: int, y: int, width: int, flip: bool = False) -> None:
    sign = -1 if flip else 1
    points = [
        (x, y),
        (x + sign * width * 0.28, y + 14),
        (x + sign * width * 0.55, y - 14),
        (x + sign * width, y),
    ]
    draw.line(points, fill=ACCENT, width=5, joint="curve")
    draw.ellipse((points[-1][0] - 5, points[-1][1] - 5, points[-1][0] + 5, points[-1][1] + 5), outline=ACCENT, width=3)


def render(src: Path, out: Path) -> None:
    image = Image.open(src).convert("RGBA")
    clean_bubble(image)

    title = font("/System/Library/Fonts/Supplemental/Luminari.ttf", 68)
    draw = ImageDraw.Draw(image)

    # Soft glow and hand-lettered color.
    shadow_layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow_layer)
    centered_text(shadow_draw, 1003, 240, "VoiceKey", title, (18, 10, 30, 140))
    image.alpha_composite(shadow_layer.filter(ImageFilter.GaussianBlur(5)))

    centered_text(draw, 1003, 234, "VoiceKey", title, (54, 32, 96, 255), stroke_width=2, stroke_fill=(214, 240, 255, 235))

    out.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(out, quality=96)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: render_voicekey_inside_bubble.py SOURCE OUTPUT")
    render(Path(sys.argv[1]), Path(sys.argv[2]))
