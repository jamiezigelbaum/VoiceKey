#!/usr/bin/env python3

from pathlib import Path
import io
import struct

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "design" / "voicekey-cyber-shrimp-app-icon-concept.png"
OUTPUT = ROOT / "Resources" / "VoiceKey.icns"

MASTER_SIZE = 1024
CORNER_RADIUS_RATIO = 0.22
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


def crop_square(image: Image.Image) -> Image.Image:
    width, height = image.size
    side = min(width, height)
    left = (width - side) // 2
    top = (height - side) // 2
    return image.crop((left, top, left + side, top + side))


def rounded_alpha_mask(size: int) -> Image.Image:
    scale = 4
    mask = Image.new("L", (size * scale, size * scale), 0)
    draw = ImageDraw.Draw(mask)
    radius = int(size * CORNER_RADIUS_RATIO * scale)
    draw.rounded_rectangle(
        (0, 0, size * scale - 1, size * scale - 1),
        radius=radius,
        fill=255,
    )
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def main() -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)

    image = Image.open(SOURCE).convert("RGBA")
    square = crop_square(image)
    master = square.resize((MASTER_SIZE, MASTER_SIZE), Image.Resampling.LANCZOS)
    master.putalpha(rounded_alpha_mask(MASTER_SIZE))

    pngs = {
        size: png_bytes(master.resize((size, size), Image.Resampling.LANCZOS))
        for size in PNG_SIZES
    }
    write_icns(OUTPUT, pngs)
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
