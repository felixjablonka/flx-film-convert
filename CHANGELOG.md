# Changelog

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
