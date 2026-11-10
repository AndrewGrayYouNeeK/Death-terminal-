#!/usr/bin/env python3
"""Pack the green-skull PNGs into a .icns file.

usage: make-icns.py <out.icns>

Uses packaging/icons/png/deathterminal-{16,32,64,128,256,512}.png.
1024 is 512 scaled up. iconutil is preferred on a Mac (see make-app.sh);
this writer is what Linux can check. It does not use any other artwork.
"""
import pathlib, struct, sys

try:
    from PIL import Image
except ImportError:
    Image = None

ROOT = pathlib.Path(__file__).resolve().parents[2]
PNG = ROOT / "packaging" / "icons" / "png"

# OSType, pixel size. ic11/ic12/ic13/ic14 are the @2x slots iconutil writes.
SLOTS = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
    ("ic11", 32),
    ("ic12", 64),
    ("ic13", 256),
    ("ic14", 512),
]


def png_bytes(size: int) -> bytes | None:
    src = PNG / f"deathterminal-{size}.png"
    if src.is_file():
        return src.read_bytes()
    if size != 1024 or Image is None:
        if size == 1024:
            print("make-icns: Pillow is not installed, so the 1024 slot is omitted", file=sys.stderr)
            return None
        raise SystemExit(f"missing {src}")
    im = Image.open(PNG / "deathterminal-512.png").convert("RGBA")
    im = im.resize((1024, 1024), Image.Resampling.LANCZOS)
    import io
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    return buf.getvalue()


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: make-icns.py <out.icns>")
    chunks = []
    for ostype, size in SLOTS:
        data = png_bytes(size)
        if data is None:
            continue
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            raise SystemExit(f"{ostype} is not a PNG")
        chunks.append(ostype.encode("ascii") + struct.pack(">I", 8 + len(data)) + data)
    body = b"".join(chunks)
    blob = b"icns" + struct.pack(">I", 8 + len(body)) + body
    pathlib.Path(sys.argv[1]).write_bytes(blob)


if __name__ == "__main__":
    main()
