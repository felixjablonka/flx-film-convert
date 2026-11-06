# Changelog

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
