# How FLX Film Convert works

FLX Film Convert prints camera scans of film negatives with FLX Film Lab's engine. Its `engine/`
folder is a snapshot of FLX Film Lab's engine sources, shader and film data (`engine/VERSION`
names the FLX Film Lab release, `engine/SNAPSHOT` its commit; `sync-engine.sh` makes a new one on
purpose, nothing syncs by itself). Its own
code is in `Sources/`: `Core/` for the conversion, `App/` for the Mac app, `CLI/` for `flxconvert`.

## From a scan to a print

1. **Decode** the raw file as FLX Film Lab does (Core Image, linear Rec.2020), at a fixed D65
   balance.
2. **The film base is the only reference.** The rebate along both long edges is one density
   everywhere, so how bright it scans along them is the scanning light: its colour, its level and
   its falloff, per channel. It is fitted along each edge, interpolated across, and lifted between
   the edges as a radial falloff does. Every pixel is measured against the base at its own position.
   A rebate can also be picked by hand. Nothing is taken from the pictures: no grey world, no
   per-frame colour.
3. **Dyes:** the densities above the base become the stock's dye amounts, through its own dye
   spectra and the decode's colour matching functions, one Newton solve per pixel
   (`Sources/Core/Scan.swift`, `Unmixer`). Treating each camera channel on its own instead turns
   Portra and Gold pink: the camera's red sees magenta dye at about half its cyan, the paper at
   0.15. The solve runs on the GPU (`Sources/Core/DyeStage.swift`): the same steps from the same
   start with the same stop, agreeing with the CPU's to 0.000001 D (median) and 0.0006 D
   (p99.99).
4. **Print:** FLX Film Lab's `print_and_scan` kernel, fed as FLX Film Lab feeds it
   (`Sources/Core/PrintStage.swift`). The stock's base goes back in, and the print time is the
   stock's own mid-grey one. Grain, couplers and halation stay off, because the scan has the real
   film's.

Left out on purpose, because the real film already did them: negative exposure and white balance,
graduated exposure, couplers, halation, scatter, grain, curve gamma.

## Roll and frame

The roll carries what belongs to the film and its processing: the film, the paper, the colour
balance (the enlarger's yellow and magenta filters) and the per-layer crossover trims. A frame can
have its own film, where a folder holds more than one roll, and its own colour balance. Each frame
carries its print: crop and straighten, exposure, brightness, contrast and split contrast, shadows,
highlights, blacks and whites, regional colour, pre-flash, detail, dodge and burn, Bloom & Glow.

Settings live in `~/Library/Application Support/FLX Film Convert/library.json`, never next to the
scans.

The film menus list only the negatives still sold new (`Sources/Core/FilmCatalogue.swift`, checked
November 2026). A roll or frame set to another keeps it.

## The film base

`RebateField` (`Sources/Core/Scan.swift`) finds the rebate in 64 places along each long edge: in
from the holder's dark surround, past the film's edge, the first band that changes only gradually
and ends in a step is rebate, unless it is a sprocket hole, which shows as a much brighter level.
A line through the bands gives each strip and its tilt. Along each strip the base is a quartic per
channel, refitted without bins that edge print or dust pull away; across, it is interpolated, with
the lift a radial falloff gives between the edges, from the strips' own curvature. When only one
edge shows clean rebate, it stands in for both. It is tuned in pixels at about 2048 on the long
side, so a bigger scan is measured reduced.

## Flat field (optional, per roll)

A frame of the bare light, shot with the roll's camera, lens, aperture and holder, can be chosen for
the roll ("Choose…" in the Roll section, or "Use as Flat Field" on a frame in the sidebar), and
switched off without forgetting it. Each scan is divided by it before the rebate is measured; the
rebate then corrects only what is left (an aperture or exposure difference). A scan from another
camera body or lens than the light frame's (by EXIF) does not use it, and the Film Base section says
why.

On a Nikon Z f with a 60 mm macro lens and an Easy35 holder (light frame at f/10, scans at f/9), the
light fell 0.10 D across the picture area, evenly in R, G and B. The rebate alone matched it to about
0.01 D rms (worst -0.03 / +0.016 D); with the flat field, the falloff the rebate still sees drops from
about 0.18 D to 0.04 D, and prints change by a median 0.4-0.7 dE76 (p95 1.7-2.2), most where the
light peaks. Use the brightest light frame that does not clip.

## Crop to Picture

The picture's edges come from the film, as the base does, never from what the picture shows
(`Sources/Core/PictureFinder.swift`). Around the picture the film was never exposed: the rebate along
the long edges and the gap between frames are bare base, flat and within about 0.15 D of it (more at
a fogged end of a roll). The gate's edge is a straight step from that band into the picture. With
the scan turned until the rebate strips are level, each edge is where the median over a whole side
steps up out of the flattest band at base level: the long edges searched from the strips inwards,
the frame ends in the outer 35% at either end. Bare light past the film's end (about 0.6 D under the
base) does not count as base. A frame end where the picture is unexposed right up to the gap is
taken where six columns in a row are as flat as base. The tilt is refined from a line through each
long edge in eight stretches (the median of pairwise slopes). The print is then levelled and cut
0.6% inside the edges.

On 107 test scans (35 mm and 120, Nikon Z 7 and Z f), 103 found all four edges; the long edges came
out level to 0.04° (median; 0.11° at p90), 35 mm pictures 1.484-1.497 wide over high. About 85 ms a
frame at the 2048-pixel preview.

## Detail

Sharpness (an unsharp mask, its radius in pixels of the full-size scan, with edge masking and halos
held to the 3 x 3 range) and local contrast (CLAHE: 8 x 8 tiles, 256 bins, a clip limit, the tiles'
curves blended by smoothstep), after NegPy's. Both work on the print's lightness (L*) and scale its
RGB to match, so they change no colour (`Sources/Core/DetailStage.swift`). They run after the print,
before Bloom & Glow. A fitted preview shows little of the sharpening; the loupe shows it at 100%.

## The loupe

The print at 100%: one pixel of the full-size print to one of the screen, under a square dragged
over the print (⌘L). The scan is decoded once at full size, flattened and kept on the GPU while the
loupe is open (0.3 s for 24 MP, 0.5 s for 45 MP); the part under it is split into dyes there
(5-12 ms) and printed (3-7 ms), with the whole print's masks and CLAHE curves, so it shows what the
export will.

## Export

JPEG or 16-bit TIFF in any of the engine's output colour spaces, at the camera's full size or
smaller, written by FLX Film Convert's copy of FLX Film Lab's exporter
(`Sources/Core/PrintExporter.swift`).

What the pictures were shot with goes into every file (`Sources/Core/ExportMetadata.swift`). The
film and the paper always go into the caption (TIFF ImageDescription, EXIF UserComment, IPTC caption;
EXIF has no tag for a film). A camera, lens (per roll, or per frame) and EI given in the Export tab
replace the scanning camera's make, model, lens and exposure, and the ISO becomes the film's speed
(its box speed, doubled per push, unless an EI is given). A date (per roll or per frame) becomes
DateTimeOriginal, and the scan's date DateTimeDigitized. Left unset, the scan's own metadata stays,
with the film and paper added.

## The sidebar

Each frame's print, made in the background when a roll opens (about 0.5 s a frame: the base measured
on a 2048-pixel decode, the print made small, on a converter of its own at utility priority) and
cached in `~/Library/Application Support/FLX Film Convert/Thumbnails`, one per frame, under the scan
file and its settings. Opening the roll again shows them at once; a frame changed is made again.

## Speed

A full-size JPEG export takes about 1.8 s for a 45 MP scan (decode 0.57 s, dyes 0.24, print 0.26,
write 0.73) and 1.1 s for 24 MP, at peaks of 4.8 and 2.9 GB of memory; `FLXCONVERT_TIMING=1` prints
each step and the memory in use. A print-control change reprints in about 12 ms at the 2048-pixel
preview.

## Open questions

- Narrowband RGB backlights would need their LED peaks in the dye model; only broadband white light
  is modelled.
- Accuracy per camera: the decode is assumed to see the dyes as the colour matching functions do.
  A test: one frame scanned with two cameras should print the same.
- A profile can disagree with the film: real Ultramax 400 negatives print cyan-blue through a profile
  that follows Kodak's datasheet.
