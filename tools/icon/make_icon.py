"""FLX Film Convert's icon as an Icon Composer document, `Resources/AppIcon.icon`,
which build.sh compiles with Xcode's actool for macOS 26's Liquid Glass (its
default, dark, clear and tinted forms). FLX Film Lab's `make_icon.py layered()`,
on this icon's dark ground instead of FLX Film Lab's white one.

The artwork, `tools/icon/AppIcon-artwork.png` (private: it stays out of the
public repository), is three dye peaks on a near-black ground. They become one
layer, cut from that ground, on a fill of the ground's own colour, glass
opaque so the colours stay the artwork's, with a shadow in the layer's own
colours. The cut un-blends the artwork's anti-aliasing: an edge pixel is the
nearest solid colour laid over the ground at some coverage, and that coverage
becomes its alpha, so no dark fringe shows on the light and clear forms.

The icon and its artwork are (c) Felix Jablonka, all rights reserved (NOTICE.md).

    python3 tools/icon/make_icon.py        (numpy, scipy, Pillow)
"""
import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

HERE = Path(__file__).resolve().parent
ARTWORK = HERE / "AppIcon-artwork.png"
LAYERED = HERE.parent.parent / "Resources" / "AppIcon.icon"
SIZE = 1024


def layered() -> Path:
    art = np.asarray(Image.open(ARTWORK).convert("RGB")).astype(np.float64) / 255
    border = np.concatenate([art[0], art[-1], art[:, 0], art[:, -1]])
    ground = np.median(border, axis=0)
    away = np.abs(art - ground).max(axis=2)
    solid = ndimage.binary_erosion(ndimage.binary_fill_holes(away > 0.25), iterations=2)
    _, (iy, ix) = ndimage.distance_transform_edt(~solid, return_indices=True)
    colour = art[iy, ix]                                  # the nearest solid colour
    span = colour - ground
    alpha = ((art - ground) * span).sum(axis=2) / np.maximum((span * span).sum(axis=2), 1e-6)
    alpha = np.where(solid, 1.0, np.clip(alpha, 0, 1))
    near = ndimage.distance_transform_edt(~solid) <= 4
    alpha = np.where(near, alpha, 0.0)
    rgba = np.dstack([colour, alpha])
    layer = Image.fromarray((rgba * 255 + 0.5).astype(np.uint8), "RGBA")
    layer = layer.convert("RGBa").resize((SIZE, SIZE), Image.LANCZOS).convert("RGBA")

    assets = LAYERED / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for stale in assets.iterdir():
        stale.unlink()
    layer.save(assets / "artwork.png", optimize=True)
    fill = ",".join(f"{v:.5f}" for v in ground) + ",1.00000"
    icon = {
        "fill": {"solid": f"extended-srgb:{fill}"},
        "groups": [{
            "layers": [{"image-name": "artwork.png", "name": "artwork"}],
            "shadow": {"kind": "layer-color", "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0.5},
        }],
        "supported-platforms": {"squares": "shared"},
    }
    (LAYERED / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")
    print(f"wrote {LAYERED} (ground {', '.join(f'{v:.3f}' for v in ground)})")
    return LAYERED


if __name__ == "__main__":
    layered()
