# Changelog

## 0.3.0 (2026-11-17)

Histogram and curves, copy and paste of print settings, two more films, and FLX Film Lab 2.0.0's engine.

### New
- **Histogram and curves** at the top of The Print, FLX Film Lab 1.4.0's: an RGB histogram of the
  finished print as its file will hold it, and point curves for all three channels and for each,
  on the print after everything else, Bloom & Glow included. Click to add a point, drag it, drag it
  off the graph to take it away; behind each curve is the histogram of what it is given. They follow
  the light or dark appearance. Exports, the loupe and the sidebar's prints carry them, and Reset
  print straightens them. `--curves` in `flxconvert`.
- **Copy and paste print settings** between frames: **Frame > Copy Print Settings** (⇧⌘C) and
  **Paste Print Settings** (⇧⌘V), the toolbar's pair, or a frame's right-click in the sidebar, which
  pastes onto that frame without opening it. The print goes across (The Print, Shadows & Highlights,
  the frame's colour balance and regional colour, Detail, Bloom & Glow, the curves), the conversion
  does not: the frame keeps its own film and picked rebate, and, as in FLX Film Lab, its crop and
  masks. A frame with print settings of its own is asked about first, as there is no undo yet.
- **Kodak Double-X 5222 and Fujifilm Neopan 100 Acros II** in the film menus. Exports give Double-X
  its daylight rating, EI 250. Agfa APX 100 and 400 stay out: FLX Film Lab builds them from
  Agfa-Gevaert's sheets of 1995, and the AgfaPhoto APX sold since 2013 is another film.

### Changed
- **The engine is FLX Film Lab 2.0.0's**, which brings the curves and the new films. Its print
  stage packs the spectral tables by band, so a print differs from 0.2.0's by rounding: at most 2
  steps of a 16-bit file (CIEDE2000 under 0.01) on eight frames across films, papers and controls,
  and on a frame with local contrast (CLAHE) one pixel 0.23 apart, where it tips a histogram bin.
  Kodak 2302, the black-and-white release print film, joins the Paper menu, as every print film of
  FLX Film Lab's does; the Konica films are in the engine but not in the film menus.
- **The shaders are compiled ahead** where Xcode's Metal compiler is installed (`build.sh`, as FLX
  Film Lab's), so the first launch no longer compiles them, and the app has a layered **Liquid Glass
  icon** made in Icon Composer's format and compiled by Xcode's `actool`, with its dark, clear and
  tinted forms. Builds use the macOS 26.5 SDK the releases are built with, also where Xcode 27 is
  installed.
- **The preview is printed in the export's colour space**, as FLX Film Lab's is, so the curves and
  the histogram act on what the file will hold. On screen, only colours outside sRGB change, where
  the display can show them.

## 0.2.0 (2026-11-10)

120 film in its own sizes, a square crop, and memory kept in check on Macs with less of it.

### New
- **Format** in the Roll section: 35 mm, or 6 × 4.5, 6 × 6, 6 × 7, 6 × 8 or 6 × 9 on 120, which the
  rebate and the picture are looked for as (`--format` in `flxconvert`). On 120 the base comes from
  the long edges only where both show and agree with the gaps between frames, and else from the
  gaps, as a carrier often covers the film's edges or leaves a sliver too thin to read; Crop to
  Picture takes a frame's length (give or take 12%) from wherever its gaps lie along the scan. 6 × 6
  and 6 × 7 were checked on real rolls, all five sizes on synthetic scans.
- **1:1** among the crop's proportions.

### Fixed
- **120 negatives.** On a roll of 6 × 6 XP2 Super, scanned in a carrier that covers the film's edges,
  the base came from a sliver of rebate a few pixels wide, blurred by the carrier, or from a flat
  foggy sky taken for a gap: up to 0.7 D off. Now every frame reads it in its gaps, the same to
  0.08 D across the roll. Crop to Picture took the scan's border for the edges the carrier covers,
  and missed frames off the scan's middle; now it finds all four edges on all 12 frames. Where a
  carrier covers a long edge, the picture's edge is where the carrier's band ends (out of focus as
  it often is), and the frame is levelled by its ends instead.
- **The gaps between frames** are looked for at the brightest level both ends of the scan share,
  as the base is the thinnest the film gets: a flat stretch of picture at the level the long edges
  wrongly suggested no longer passes for them. No 35 mm frame among 238 changed.
- **Memory.** A 45 MP frame takes 3 to 6 GB while it is decoded and printed at full size, and the
  loupe and an export could do it at once while the sidebar's prints were being made, enough to push
  a 16 GB Mac out of memory, which stalls the app until it is force-quit. Full-size work now goes one
  at a time; when macOS says memory runs short, the app lets go of the other frames' scans and the
  loupe's full-size frame (unless the loupe is open), and at critical stops making sidebar prints;
  each preview render drains what Metal autoreleases, which a dragged slider let pile up; and an
  export no longer waits on the render queue from the main thread.
- `flxconvert --read-metadata FILE` works as the README gives it: it needed `--film` and took only
  files named before the option.
- A relative `--flat` path is read from the folder `flxconvert` was started in.

## 0.1.2 (2026-11-07)

Five more Ilford films.

### New
- **Ilford Delta 100, Delta 400, FP4 Plus, Pan F Plus and Ortho Plus** join HP5 Plus in the film
  menus: the profiles FLX Film Lab 1.4.0 builds from HARMAN's own technical information. Exports
  give each its speed as its sheet rates it to daylight: ISO 100, 400, 125, 50 and 80.

The engine is still FLX Film Lab 1.3.0's, with only these five films added, so every other film
prints as before.

## 0.1.1 (2026-11-06)

The rebate on black-and-white film, the gaps between frames where no long edge shows it, and
sharpening on from the start.

### New
- **The gaps between frames** at the short ends give the base where neither long edge shows clean
  rebate.

### Changed
- **Sharpness starts at 100%** (it was off): on a new frame, after Reset detail, and in
  `flxconvert` without `--sharpness`. A double-click on the slider puts it back to 100%.

### Fixed
- **The rebate on black-and-white film.** The finder often put a strip into the picture or found
  none: next to a dense part of the picture, light spread across the gate's edge fogs the rebate,
  and a thin picture runs on at nearly the base's level. It now also tries the clean base further
  out, by the sprocket holes, fits the two edges together so a fogged stretch of one drops out, and
  keeps its fit from swinging through stains or past the last clean stretch. On a roll of HP5 Plus,
  31 of 34 frames now give both edges (20 before), and none is left without a base.
- **Crop to Picture** finds a long edge whose rebate is fogged, and levels the frame only from the
  edges with rebate of their own, so a stain on the other no longer tilts it.
- A missing edge's stand-in is no longer drawn on the scan as if it had been found, and it runs
  parallel to the edge that was.

## 0.1.0 (2026-11-06)

The first public version: camera scans of film negatives printed with FLX Film Lab 1.3.0's engine.

- **The film base as the only reference:** the rebate along both long edges gives the scanning
  light's colour, level and falloff, per channel; or a rebate picked by hand. Nothing is set from the
  pictures.
- **Each negative read through its stock's dyes** and printed on one of FLX Film Lab's papers, with
  its print controls, regional colour, pre-flash, dodge and burn, and Bloom & Glow.
- **A roll at a time:** film, paper and colour balance for the roll, and a film or colour balance of
  a frame's own; every frame's print in the sidebar, cached.
- **Crop to Picture,** levelled and cut from the film's own edges.
- **Flat field** from a frame of the bare scanning light.
- **Detail:** sharpness and local contrast (CLAHE), and a loupe at 100%.
- **Export** to JPEG or 16-bit TIFF, naming the film and paper, with the camera, lens, date and film
  speed given in the Export tab.
- **`flxconvert`,** the same conversion from the command line.
