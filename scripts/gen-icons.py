#!/usr/bin/env -S uv run --script --quiet
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Draw the Recorder icon and write every size the app and the web viewer use.

The mark is a record button: a Signal Orange disc inside a thin orange ring on a
flat dark ground, in the family of cf-thunder and max-pane.

    ./scripts/gen-icons.py

macOS 26 draws app icons inside its own squircle with a glass rim, and an opaque
full-bleed square gets clipped with a pale ring showing. So the .icns art is masked
to Apple's squircle at 824 of 1024 points on a transparent canvas, as max-pane does.
The web icons stay full-bleed squares. Outputs are committed; the build doesn't run this.
"""
import subprocess, tempfile
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BG = (0x1A, 0x1A, 0x1A, 255)
ORANGE = (0xE8, 0x5D, 0x00, 255)
SUPER = 4

# Proportions of the square, from the centre.
RING_OUTER = 0.33
RING_WIDTH = 0.03
DISC = 0.245


def mark(size: int) -> Image.Image:
    big = size * SUPER
    img = Image.new("RGBA", (big, big), BG)
    d = ImageDraw.Draw(img)
    c = big / 2
    def circle(r, fill):
        d.ellipse((c - r * big, c - r * big, c + r * big, c + r * big), fill=fill)
    circle(RING_OUTER, ORANGE)
    circle(RING_OUTER - RING_WIDTH, BG)
    circle(DISC, ORANGE)
    return img.resize((size, size), Image.LANCZOS)


def squircle(size: int, art: int) -> Image.Image:
    a = mark(art)
    m = Image.new("L", (art * SUPER, art * SUPER), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, art * SUPER - 1, art * SUPER - 1), radius=art * 0.2237 * SUPER, fill=255)
    a.putalpha(m.resize((art, art), Image.LANCZOS))
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - art) // 2
    canvas.paste(a, (off, off), a)
    return canvas


def svg() -> str:
    s = 512
    r = lambda f: round(f * s, 1)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {s} {s}"><rect width="{s}" height="{s}" fill="#1a1a1a"/>'
            f'<circle cx="256" cy="256" r="{r(RING_OUTER - RING_WIDTH / 2)}" fill="none" stroke="#e85d00" stroke-width="{r(RING_WIDTH)}"/>'
            f'<circle cx="256" cy="256" r="{r(DISC)}" fill="#e85d00"/></svg>\n')


def main() -> None:
    master = squircle(1024, 824)
    master.save(ROOT / "Resources/AppIcon.png")
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for s in [16, 32, 128, 256, 512]:
            master.resize((s, s), Image.LANCZOS).save(iconset / f"icon_{s}x{s}.png")
            master.resize((s * 2, s * 2), Image.LANCZOS).save(iconset / f"icon_{s}x{s}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "Resources/AppIcon.icns")], check=True)

    web = ROOT / "web/public/recordings/icons"
    web.mkdir(parents=True, exist_ok=True)
    (web / "icon.svg").write_text(svg())
    for name, s in [("icon-192.png", 192), ("icon-512.png", 512), ("apple-touch-icon.png", 180)]:
        mark(s).convert("RGB").save(web / name)
    print("wrote Resources/AppIcon.icns, Resources/AppIcon.png, web/public/recordings/icons/*")


if __name__ == "__main__":
    main()
