#!/usr/bin/env python3
"""Rebuild ONLY selected production PNGs from an already extracted temp library.

Usage: python3 ios/scripts/prepare-rarity-vfx.py /absolute/temp/library
Requires Pillow. Never writes into the source library or Downloads.
"""
import json
import sys
from pathlib import Path
from PIL import Image

source = Path(sys.argv[1]).resolve()
output = Path(__file__).resolve().parents[1] / "Sources/NutriQuest/Resources/RarityVFX"
selections = {
    "epic": [source / f"FreeGameFX/S-PNG Frames/67/67{i:04d}.png" for i in range(20)],
    "gold": [source / f"FreeGameFX/S-PNG Frames/69/69{i:04d}.png" for i in range(20)],
    "red": [source / f"FreeGameFX/S-PNG Frames/72/72{i:04d}.png" for i in range(20)],
    "flame": [source / f"FreeStylizedSpriteVFX/Bonfire/{i}.png" for i in range(1, 17)],
    # 0090 is the duplicate loop endpoint; sample the 90-frame cycle uniformly.
    "smoke": [source / f"SmokeAura/{i:04d}.png" for i in range(0, 90, 3)],
    "mote": [source / "KenneyParticlePack/PNG (Transparent)/circle_05.png"],
    "spark": [source / "KenneyParticlePack/PNG (Transparent)/star_04.png"],
}
records = []
for name, paths in selections.items():
    frames = [Image.open(p).convert("RGBA") for p in paths]
    # One shared crop, never a per-frame crop (which would change the anchor).
    if name == "flame":
        boxes = [im.getchannel("A").getbbox() for im in frames]
        bounds = (min(b[0] for b in boxes) - 12, min(b[1] for b in boxes) - 12,
                  max(b[2] for b in boxes) + 12, max(b[3] for b in boxes) + 12)
        frames = [im.crop(bounds) for im in frames]
    else:
        bounds = None
    for index, (path, im) in enumerate(zip(paths, frames)):
        im.thumbnail((64, 64) if name in ("mote", "spark") else (256, 256), Image.Resampling.LANCZOS)
        folder = output / name
        folder.mkdir(parents=True, exist_ok=True)
        destination = folder / f"{name}_{index:03d}.png"
        im.save(destination, optimize=True)
        records.append({"source": str(path.relative_to(source)),
                        "production": str(destination.relative_to(output)),
                        "size": im.size, "shared_crop": bounds})
# Provenance is documentation, not an application resource.
provenance = Path(__file__).resolve().parents[2] / "docs/rarity-vfx-assets.json"
provenance.write_text(json.dumps(records, indent=2) + "\n")
print(f"Prepared {len(records)} PNGs; {sum(p.stat().st_size for p in output.rglob('*.png')):,} bytes")
