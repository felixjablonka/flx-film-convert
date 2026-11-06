#!/usr/bin/env python
"""Draw the picture GitHub shows when the repository is shared (uploaded by
hand, under Settings, General, Social preview): `tools/icon/social-preview.png`,
1280 x 640.

FLX Film Lab's own preview, in the same form: the icon masked to its rounded
square as macOS draws it, the app's name and its line on a darkroom-dark
ground. FLX Film Convert's icon is the negative of FLX Film Lab's, on a ground
nearly as dark as the card's, so its edge is drawn as a faint light hairline,
as a dark icon needs on a dark page.

The icon comes out of `Resources/AppIcon.icns`, at 1024 px. It is © Felix
Jablonka, all rights reserved (NOTICE.md), and so is this picture.

Run:  conda activate flx-bake && python tools/icon/social_preview.py
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = Path(__file__).resolve().parents[2]
ICNS = REPO / "Resources" / "AppIcon.icns"
OUT = Path(__file__).resolve().parent / "social-preview.png"
FONT = "/System/Library/Fonts/Avenir Next.ttc"
GROUND = (19, 20, 23)


def artwork() -> Image.Image:
    """The icon's 1024 px square, from the .icns the app ships."""
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        subprocess.run(["iconutil", "-c", "iconset", str(ICNS), "-o", str(iconset)], check=True)
        return Image.open(iconset / "icon_512x512@2x.png").convert("RGB").copy()


def superellipse(size: int, inset: float = 0.0) -> Image.Image:
    """macOS's rounded square with continuous corners (exponent 5), drawn at
    4x and reduced; `inset` shrinks it by that many pixels of `size`."""
    big = size * 4
    t = np.abs((np.arange(big) + 0.5) / big * 2 - 1) * size / (size - 2 * inset)
    u, v = np.meshgrid(t, t)
    return Image.fromarray(((u ** 5 + v ** 5 <= 1) * 255).astype(np.uint8), "L").resize((size, size), Image.LANCZOS)


def rounded(size: int) -> Image.Image:
    """The icon as macOS draws it, with a hairline of light just inside its
    edge so it holds on a dark ground."""
    icon = artwork().resize((size, size), Image.LANCZOS).convert("RGBA")
    outer = superellipse(size)
    inner = superellipse(size, inset=1.5)
    rim = np.clip(np.asarray(outer, float) - np.asarray(inner, float), 0, 255) / 255
    px = np.asarray(icon, float)
    px[..., :3] = px[..., :3] * (1 - 0.22 * rim[..., None]) + 255 * 0.22 * rim[..., None]
    icon = Image.fromarray(px.round().astype(np.uint8), "RGBA")
    icon.putalpha(outer)
    return icon


def shadow(icon: Image.Image, canvas: tuple[int, int], at: tuple[int, int],
           blur: float, offset: int, opacity: float) -> Image.Image:
    layer = Image.new("RGBA", canvas, (0, 0, 0, 0))
    alpha = icon.getchannel("A").point(lambda a: round(a * opacity))
    layer.paste((0, 0, 0, 255), (at[0], at[1] + offset), alpha)
    return layer.filter(ImageFilter.GaussianBlur(blur))


def font(style: str, size: int) -> ImageFont.FreeTypeFont:
    for index in range(32):
        try:
            face = ImageFont.truetype(FONT, size, index=index)
        except OSError:
            break
        if face.getname()[1] == style:
            return face
    raise LookupError(f"no Avenir Next {style} in {FONT}")


def social_preview() -> Path:
    width, height = 1280, 640
    out = Image.new("RGBA", (width, height), GROUND + (255,))
    body = 320
    at = (104, (height - body) // 2)
    icon = rounded(body)
    out.alpha_composite(shadow(icon, (width, height), at, blur=18, offset=10, opacity=0.6))
    out.alpha_composite(icon, at)

    # Text, style, size, colour, and the space above it.
    lines = [
        ("FLX Film Convert", "Demi Bold", 88, (245, 245, 247), 0),
        ("A Mac app that turns camera scans", "Regular", 36, (199, 201, 207), 26),
        ("of film negatives into prints.", "Regular", 36, (199, 201, 207), 6),
        ("The film base as reference · a companion to FLX Film Lab", "Medium", 24, (138, 141, 150), 30),
    ]
    faces = [font(style, size) for _, style, size, _, _ in lines]
    heights = [sum(face.getmetrics()) for face in faces]
    x = at[0] + body + 64
    y = (height - sum(heights) - sum(line[4] for line in lines)) / 2
    draw = ImageDraw.Draw(out)
    for (text, _, _, colour, above), face, line_height in zip(lines, faces, heights):
        y += above
        right = x + face.getlength(text)
        assert right <= width - 56, f"too wide by {right - (width - 56):.0f} px: {text}"
        draw.text((x, y), text, font=face, fill=colour, anchor="la")
        y += line_height
    out.convert("RGB").save(OUT, optimize=True)
    print(f"wrote {OUT} ({OUT.stat().st_size / 1024:.0f} KB)")
    return OUT


if __name__ == "__main__":
    social_preview()
