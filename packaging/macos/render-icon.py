#!/usr/bin/env python3
"""Rasterize the green-skull logo into the macOS iconset and Flatpak icons.

Source is site/logo.png only. This does not read packaging/icons/ (that set
is a different export, and older packaging art was a white skull on a black
window). site/logo.png is 256x256, so sizes above 256 are upscaled.

    python3 packaging/macos/render-icon.py
"""

import struct
import sys
from io import BytesIO
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
LOGO = ROOT / "site" / "logo.png"
# 1024 source for the Dock icon. CFBundleIconFile is "deathterminal".
DOCK = ROOT / "packaging" / "macos" / "AppIcon-1024.png"
DOCK_ICNS = ROOT / "packaging" / "macos" / "deathterminal.icns"
ICONSET = ROOT / "packaging" / "macos" / "DeathTerminal.iconset"
ICNS = ROOT / "packaging" / "macos" / "DeathTerminal.icns"
FLATPAK_ICONS = ROOT / "packaging" / "flatpak" / "icons" / "hicolor"

# Apple iconutil names. @2x files are the pixel size in the name's scale.
ICONSET_FILES = (
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
)

# OSTypes used by a modern .icns (PNG payloads). ic11–ic14 are the @2x types.
ICNS_TYPES = (
    ("icp4", 16),
    ("icp5", 32),
    ("ic11", 32),
    ("ic12", 64),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic13", 256),
    ("ic09", 512),
    ("ic14", 512),
    ("ic10", 1024),
)

FLATPAK_SIZES = (16, 32, 48, 64, 128, 256, 512)


def png_size(blob):
    if blob[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("icon payload is not a PNG")
    width, height = struct.unpack(">II", blob[16:24])
    return width, height


def assert_green_skull(image):
    pixels = list(image.getdata())
    white = 0
    green = 0
    for pixel in pixels:
        red, green_ch, blue, alpha = pixel
        if alpha > 200 and red > 230 and green_ch > 230 and blue > 230:
            white += 1
        if alpha > 200 and green_ch > red + 40 and green_ch > 100:
            green += 1
    if white > len(pixels) * 0.02:
        raise SystemExit("site/logo.png looks like a white-skull icon; refusing to package it")
    if green < 1000:
        raise SystemExit("site/logo.png does not contain the green skull")


def resized(master, size):
    if master.size == (size, size):
        return master
    return master.resize((size, size), Image.Resampling.LANCZOS)


def png_bytes(image):
    buf = BytesIO()
    image.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def write_icns(path, pngs_by_size):
    chunks = []
    for ostype, size in ICNS_TYPES:
        blob = pngs_by_size[size]
        if png_size(blob) != (size, size):
            raise SystemExit(f"{ostype} is not {size}x{size}")
        chunks.append(ostype.encode("ascii") + struct.pack(">I", 8 + len(blob)) + blob)
    body = b"".join(chunks)
    path.write_bytes(b"icns" + struct.pack(">I", 8 + len(body)) + body)


def check_icns(path, pngs_by_size):
    data = path.read_bytes()
    if data[:4] != b"icns":
        raise SystemExit("DeathTerminal.icns magic is not icns")
    total = struct.unpack(">I", data[4:8])[0]
    if total != len(data):
        raise SystemExit("DeathTerminal.icns length header does not match the file")
    offset = 8
    seen = []
    while offset < len(data):
        ostype = data[offset : offset + 4].decode("ascii")
        length = struct.unpack(">I", data[offset + 4 : offset + 8])[0]
        blob = data[offset + 8 : offset + length]
        seen.append((ostype, png_size(blob)))
        offset += length
    expected = [(ostype, (size, size)) for ostype, size in ICNS_TYPES]
    if seen != expected:
        raise SystemExit(f"icns types {seen} != {expected}")
    for size, blob in pngs_by_size.items():
        if png_size(blob) != (size, size):
            raise SystemExit(f"cached png {size} has the wrong size")


def write_dock_icns():
    """Dock icon from the 1024 PNG. Every size is a downsample, not an upscale."""
    if not DOCK.is_file():
        raise SystemExit(f"missing {DOCK}")
    master = Image.open(DOCK).convert("RGBA")
    if master.size != (1024, 1024):
        raise SystemExit(f"expected AppIcon-1024.png to be 1024x1024, got {master.size}")
    assert_green_skull(master)
    pngs_by_size = {}
    for size in sorted({size for _, size in ICNS_TYPES}):
        pngs_by_size[size] = png_bytes(resized(master, size))
    write_icns(DOCK_ICNS, pngs_by_size)
    check_icns(DOCK_ICNS, pngs_by_size)
    print(f"wrote {DOCK_ICNS}")


def main():
    write_dock_icns()
    if not LOGO.is_file():
        raise SystemExit(f"missing {LOGO}")
    master = Image.open(LOGO).convert("RGBA")
    if master.size != (256, 256):
        raise SystemExit(f"expected site/logo.png to be 256x256, got {master.size}")
    assert_green_skull(master)

    pngs_by_size = {}
    for size in sorted({size for _, size in ICONSET_FILES} | set(FLATPAK_SIZES)):
        pngs_by_size[size] = png_bytes(resized(master, size))

    ICONSET.mkdir(parents=True, exist_ok=True)
    for name, size in ICONSET_FILES:
        (ICONSET / name).write_bytes(pngs_by_size[size])
    write_icns(ICNS, pngs_by_size)
    check_icns(ICNS, pngs_by_size)

    for size in FLATPAK_SIZES:
        dest = FLATPAK_ICONS / f"{size}x{size}" / "apps" / "org.youneek.DeathTerminal.png"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(pngs_by_size[size])
        if png_size(dest.read_bytes()) != (size, size):
            raise SystemExit(f"flatpak icon {size} has the wrong size")

    print(f"wrote {ICNS}")
    print(f"wrote {ICONSET}")
    print(f"wrote {FLATPAK_ICONS}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
