#!/usr/bin/env python3
"""Generate Resources/VoiceKey.icns procedurally.

macOS-style rounded tile: a deep indigo -> violet gradient carrying a white
speech-bubble glyph (echoing the menu bar icon) with a four-bar waveform
knocked out of it. Also writes the 1024px master to design/ for reference.

Usage: python3 -m venv /tmp/voicekey-icon-venv && \\
    /tmp/voicekey-icon-venv/bin/pip install pillow && \\
    /tmp/voicekey-icon-venv/bin/python scripts/generate_app_icon.py
"""

from pathlib import Path
import io
import struct

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Resources" / "VoiceKey.icns"
MASTER_OUTPUT = ROOT / "design" / "voicekey-app-icon-master.png"

MASTER_SIZE = 1024
SUPERSAMPLE = 4
CORNER_RADIUS_RATIO = 0.2237  # matches the macOS icon tile shape
PNG_SIZES = [16, 32, 64, 128, 256, 512, 1024]
ICNS_CHUNKS = [
    ("icp4", 16),    # 16x16
    ("icp5", 32),    # 32x32
    ("ic11", 32),    # 16x16@2x
    ("icp6", 64),    # 64x64
    ("ic12", 64),    # 32x32@2x
    ("ic07", 128),   # 128x128
    ("ic08", 256),   # 256x256
    ("ic13", 256),   # 128x128@2x
    ("ic09", 512),   # 512x512
    ("ic14", 512),   # 256x256@2x
    ("ic10", 1024),  # 512x512@2x
]

GRADIENT_TOP = (43, 27, 89)      # deep indigo
GRADIENT_BOTTOM = (124, 58, 237)  # violet

# Bubble geometry in 1024px master coordinates; proportions echo the
# menu bar glyph (66x42 rounded body, tail at the lower left).
BUBBLE_RECT = (212, 290, 812, 670)  # left, top, right, bottom
BUBBLE_RADIUS = 170
TAIL_POLYGON = [(330, 615), (322, 705), (344, 792), (384, 786), (460, 650)]
TAIL_TIP = (364, 789)
TAIL_TIP_RADIUS = 22
BAR_WIDTH = 60
BAR_SPACING = 105
BAR_HEIGHTS = [170, 290, 230, 140]
BUBBLE_CENTER = (512, 480)


def s(value: float) -> int:
    return round(value * SUPERSAMPLE)


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    gray = Image.linear_gradient("L").resize((size, size))
    channels = [
        gray.point([round(t + (b - t) * i / 255) for i in range(256)])
        for t, b in zip(top, bottom)
    ]
    return Image.merge("RGB", channels)


def add_top_glow(image: Image.Image, size: int) -> None:
    radial = Image.radial_gradient("L").resize((size, size))
    mask = radial.point(lambda i: int(26 * (1 - i / 255)))
    glow = Image.new("RGB", (size, size), (255, 255, 255))
    image.paste(glow, (0, 0), mask)


def draw_bubble(draw: ImageDraw.ImageDraw, fill) -> None:
    left, top, right, bottom = (s(v) for v in BUBBLE_RECT)
    draw.rounded_rectangle((left, top, right, bottom), radius=s(BUBBLE_RADIUS), fill=fill)
    draw.polygon([(s(x), s(y)) for x, y in TAIL_POLYGON], fill=fill)
    r = s(TAIL_TIP_RADIUS)
    tip_x, tip_y = TAIL_TIP
    draw.ellipse((s(tip_x) - r, s(tip_y) - r, s(tip_x) + r, s(tip_y) + r), fill=fill)


def knock_out_bars(draw: ImageDraw.ImageDraw) -> None:
    first_x = BUBBLE_CENTER[0] - (3 * BAR_SPACING + BAR_WIDTH) / 2
    for index, height in enumerate(BAR_HEIGHTS):
        x = first_x + index * BAR_SPACING
        y = BUBBLE_CENTER[1] - height / 2
        draw.rounded_rectangle(
            (s(x), s(y), s(x + BAR_WIDTH), s(y + height)),
            radius=s(BAR_WIDTH / 2),
            fill=(0, 0, 0, 0),
        )


def rounded_alpha_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size * 4, size * 4), 0)
    draw = ImageDraw.Draw(mask)
    radius = int(size * CORNER_RADIUS_RATIO * 4)
    draw.rounded_rectangle((0, 0, size * 4 - 1, size * 4 - 1), radius=radius, fill=255)
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def render_master() -> Image.Image:
    size = MASTER_SIZE * SUPERSAMPLE

    tile = vertical_gradient(size, GRADIENT_TOP, GRADIENT_BOTTOM).convert("RGBA")
    add_top_glow(tile, size)

    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw_bubble(ImageDraw.Draw(shadow), fill=(0, 0, 0, 70))
    shadow = shadow.filter(ImageFilter.GaussianBlur(s(14)))
    offset = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    offset.paste(shadow, (0, s(18)))
    tile = Image.alpha_composite(tile, offset)

    bubble = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bubble_draw = ImageDraw.Draw(bubble)
    draw_bubble(bubble_draw, fill=(255, 255, 255, 255))
    knock_out_bars(bubble_draw)
    tile = Image.alpha_composite(tile, bubble)

    master = tile.resize((MASTER_SIZE, MASTER_SIZE), Image.Resampling.LANCZOS)
    master.putalpha(rounded_alpha_mask(MASTER_SIZE))
    return master


def main() -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)

    master = render_master()
    MASTER_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    master.save(MASTER_OUTPUT, format="PNG")

    pngs = {
        size: png_bytes(master.resize((size, size), Image.Resampling.LANCZOS))
        for size in PNG_SIZES
    }
    write_icns(OUTPUT, pngs)
    print(MASTER_OUTPUT)
    print(OUTPUT)


def png_bytes(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def write_icns(output: Path, pngs: dict[int, bytes]) -> None:
    entries = []
    for chunk_type, size in ICNS_CHUNKS:
        data = pngs[size]
        entries.append(chunk_type.encode("ascii") + struct.pack(">I", len(data) + 8) + data)

    body = b"".join(entries)
    output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    main()
