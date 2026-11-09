# SlicePad

A basic slicer for the **Bambu Lab A1 mini** (with AMS lite), built for iPad.
Import an STL, preview it in 3D, slice it with the A1 mini's own G-code
sequences and profiles researched from Bambu Studio's open source, and send
the result to the printer over WiFi — **no Bambu account involved**.

📖 The full research behind the G-code, the file format, the flow numbers
and the LAN protocol is in [RESEARCH.md](RESEARCH.md).

## What it does

- **STL import** (binary + ASCII) with a Metal 3D preview — orbit, pinch
  zoom, pan — plus a toolpath view with a layer slider.
- **Slicing** with the `0.20mm Standard @BBL A1M` profile as the baseline:
  perimeters (2 walls by default), grid infill (15 %), solid top/bottom
  shells, optional skirt/brim. Layer height, walls, infill, temps, flow
  ratio and brim are adjustable.
- **Real A1 mini G-code**: the start/end sequences are Bambu Studio's own
  A1 mini templates, rendered with this print's values — AMS lite load
  bracket (`M620/M621`), bed levelling, the printer's own extrusion
  calibration block, and the end-of-print unload.
- **Flow enforced the way Bambu Studio does it**: every extrusion move is
  clamped to the selected filament's volumetric limit (Bambu PLA Basic
  21 mm³/s, Generic PLA 12, Bambu PETG Basic 13). No pressure-advance
  commands — the A1 calibrates flow on-device.
- **Time estimate** from an acceleration-aware planner over the emitted
  moves, shown in the app and written into the file header.
- **Output: `.gcode.3mf`** — the container the A1 mini needs for AMS use,
  preview and WiFi start (plain `.gcode` can't drive the AMS; the research
  explains why). A plain `.gcode` export is included, labelled
  *external spool only*.
- **WiFi send + AMS sync**: discovers the printer on the LAN (or takes an
  IP), reads the AMS lite's loaded filaments (type, colour, preset) and
  printer status over MQTT, uploads the sliced file over FTPS and can
  start the print — all with LAN Only Mode + Developer Mode and the
  printer's LAN access code. **No Bambu account, no cloud.**

## What it deliberately doesn't do (v1)

- No supports, no variable layer height, no ironing, no multi-filament
  prints in one job (one AMS slot per print), no tree/organic anything.
- AMS lite remaining-% is never shown: the printer doesn't report it.
- Time estimates are estimates — first prints will show how close.

## Printer setup (one time)

1. On the A1 mini: **Settings → Network → LAN Only Mode: ON**, and
   **Developer Mode: ON** (needed for third-party upload/start;
   firmware ≥ 01.05.00.00). This disconnects Bambu Handy/cloud while on.
2. Read the printer's **IP address**, **serial number** and **LAN access
   code** from its screen.
3. In SlicePad's Printer tab, enter them (or tap Discover). The access
   code is stored in the iPad Keychain only.

Or skip WiFi: export the `.gcode.3mf`, copy it to the **root of a FAT32
microSD card**, and start it from the printer's touchscreen.

## Status

⚠️ **Printer verification pending.** The slicer core is validated by host
tests in CI (geometry bounds, volumetric-cap audit, template rendering,
3MF structure). The output has been researched from Bambu's own sources,
but no SlicePad file has been printed yet — the first test print on a
real A1 mini is what promotes this from "researched" to "verified".

## Building

Unsigned IPA via GitHub Actions (`.github/workflows/build-ipa.yml`):
a host-test job compiles the slicer core with `swiftc` and runs the
validation harness; the build job produces an unsigned IPA on the free
standard `macos-26` runner.

## Licence / credits

SlicePad's own code is MIT (see repository). The G-code templates in
`App/SlicePad/Resources/` are Bambu Lab's profile data from the
BambuStudio project (GPLv3) — they are printer configuration data,
reproduced so prints behave like Bambu Studio's own output; see
[RESEARCH.md](RESEARCH.md) for provenance.
