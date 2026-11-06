# Notices and attribution

FLX Film Convert is licensed under the **GNU General Public License v3.0** (see `LICENSE`).
Copyright © 2026 Felix Jablonka.

## FLX Film Lab

Copyright © 2026 Felix Jablonka — <https://github.com/felixjablonka/flx-film-lab>

FLX Film Convert prints with FLX Film Lab's engine. `engine/` is a snapshot of FLX Film Lab 1.3.0's
engine sources, its Metal shader and its film and paper data, copied by `sync-engine.sh`
(`engine/SNAPSHOT` names the commit), and built unchanged. These files in `Sources/` are FLX Film
Lab's too, copied and adapted:

- `Sources/App/CropOverlay.swift` and `Sources/App/MaskOverlay.swift`: the crop and the
  dodge-and-burn masks drawn on the print
- `Sources/App/ControlVocabulary.swift`: the sliders' photographic names and their mapping onto the
  engine's darkroom quantities
- `Sources/Core/PrintExporter.swift`: the exporter, writing the files' profile and metadata

The inspector's slider rows (a double-click resets, a dot marks a changed value) and its sections
follow FLX Film Lab's.

FLX Film Lab is GPLv3. Its `NOTICE.md` lists what it builds on.

## agx-emulsion / spektrafilm

Copyright © Andrea Volpato — <https://github.com/andreavolpato/spektrafilm>

FLX Film Lab's engine is a port of spektrafilm's physical model to Metal, so FLX Film Convert prints
through it too. spektrafilm is GPLv3, and its author states that derivative work includes software
directly inspired by its methods. FLX Film Convert is therefore GPLv3.

Film modelling powered by `spektrafilm`.

### Profile data — CC BY-SA 4.0

The contents of `engine/FLXFilmLab/Resources/packs/` are FLX Film Lab's film and paper packs,
derived from spektrafilm's profile JSONs and spectral LUTs and from manufacturers' datasheets, and
licensed **CC BY-SA 4.0** (`engine/FLXFilmLab/Resources/packs/LICENSE-CC-BY-SA-4.0.txt`).
Attribution: spektrafilm profiles by Andrea Volpato; the profiles FLX Film Lab builds itself are
listed in its `NOTICE.md`.

## NegPy

Copyright © marcinz606 and contributors — <https://github.com/marcinz606/NegPy>

No NegPy code is included. FLX Film Convert follows NegPy's documented methods in:

- **CLAHE local contrast** on the print's L*: a fixed 8 x 8 tile grid over the whole print, 256 bins,
  a clip limit of 2.5 times the strength, the four nearest tiles' curves blended by smoothstep, and
  the result blended in by the strength
- **sharpening** as an unsharp mask on L*, its radius in output pixels, with the overshoot held to
  the 3 x 3 neighbourhood's range and an edge mask from the gradient of L*
- **capture metadata:** the camera, lens and film speed a picture was taken with written into the
  export's standard EXIF tags in place of the scanning camera's

NegPy is GPLv3.

## The app icon and the screenshots

`Resources/AppIcon.icns`, `docs/images/icon.png` and `tools/icon/social-preview.png` are © Felix
Jablonka, all rights reserved. Neither the GPLv3 nor CC BY-SA covers them; a fork needs its own icon. The same holds for the
photographs in the screenshots, `docs/images/overview.jpg`, `scan.jpg` and `loupe.jpg`.
