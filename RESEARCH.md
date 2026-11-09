# SlicePad — A1 mini / AMS lite research

Everything SlicePad knows about the Bambu Lab A1 mini and its AMS lite was
researched before any code was written, primarily from **Bambu Studio's own
open source** (github.com/bambulab/BambuStudio, profiles + slicer source,
commit `9aacb21bd642b0591ef4221aa7bbc05ae6b21ef3`), cross-checked against
Bambu's wiki and the community's reverse-engineering of the LAN protocol
(OpenBambuAPI, pybambu / ha-bambulab). Where a fact is community-sourced
rather than official, it says so. Bambu publishes **no official G-code
reference**; the M-code semantics below come from comments inside Bambu's
own profile templates (primary) and community documentation (secondary).

The verbatim G-code templates ship in the app at
`App/SlicePad/Resources/` — extracted character-for-character from the
profile JSONs named below, and rendered at slice time by a small template
engine that implements exactly the placeholder constructs those files use.

---

## 1. The machine — hard numbers

Source: `resources/profiles/BBL/machine/Bambu Lab A1 mini.json`,
`Bambu Lab A1 mini 0.4 nozzle.json` (inherits `fdm_bbl_3dp_001_common` →
`fdm_machine_common`), process `0.20mm Standard @BBL A1M`.

| Fact | Value |
|---|---|
| Build volume | **180 × 180 × 180 mm** (`printable_area` 0,0–180,180, height 180) |
| Stock nozzle | 0.4 mm (0.2 / 0.6 / 0.8 variants exist) |
| Machine speed caps | X/Y 500 mm/s, travel accel 9000 mm/s², X/Y accel 20000 mm/s² |
| Process defaults (0.20 mm Standard) | layer 0.20, **2 walls**, top shell 5, bottom shell 3, infill **15 % grid**, line width 0.42 (inner 0.45), outer wall 200 mm/s, inner wall 300, infill 270, top surface 200, first layer 50, travel 700 (→ capped 500 by machine) |
| Retraction (direct drive) | **0.8 mm @ 30 mm/s**, deretract 30 mm/s |
| PLA temps (Bambu PLA Basic / Generic PLA, Textured PEI) | nozzle **220 °C**, bed **65 °C** |
| Filament | 1.75 mm; E-flow constant 2.4053 mm² (= π·0.875²) used throughout Bambu's templates |

## 2. The G-code dialect

A Bambu plate file is three blocks: a `HEADER_BLOCK` of `;` comments
(slicer id, `; model printing time:`, `; total layer number:`, filament
density/diameter, max Z), a full `CONFIG_BLOCK` settings dump, and the
`EXECUTABLE_BLOCK`: machine start template → body with `M73 P<%> R<min>`
progress lines and `M624/M625` object brackets → machine end template,
plus footer `; filament used [mm/cm3/g]` lines.

### Start G-code (A1 mini, 0.4 nozzle — the load-bearing excerpts)

Full text: `App/SlicePad/Resources/start_gcode.txt` (473 lines, from
`Bambu Lab A1 mini 0.4 nozzle template machine_start_gcode.json`). The
parts that matter for a single-filament AMS print:

```gcode
M1002 gcode_claim_action : 2
M1002 set_filament_type:{filament_type[initial_no_support_extruder]}
...
M620 M          ; enable filament↔AMS-slot mapping at print start
;===== start to load filament =====
M620 S[initial_no_support_extruder]A
M109 S{nozzle_temperature_initial_layer[initial_no_support_extruder]-20}
...
T[initial_no_support_extruder]
M109 S{nozzle_temperature_initial_layer[initial_no_support_extruder]}
...
M620.1 E F{flush_volumetric_speeds[initial_no_support_extruder]/2.4053*60} T{flush_temperatures[initial_no_support_extruder]}
G1 E50 F{flush_volumetric_speeds[initial_no_support_extruder]/2.4053*60}     ; purge
...
M621 S[initial_no_support_extruder]A
```

i.e. **the first filament is loaded by the start sequence itself** — the
stock end G-code (below) unloads at the end of every print, so nothing is
"pre-loaded". Later in the start template: `M412 S1` (filament runout
detection on), `M620.3 W1` (tangle detection), auto bed levelling, and an
**extrusion-calibration block gated by printer-side flags**
(`M1002 judge_flag extrude_cali_flag` / `M622 J1` → `M983`/`M984`
dynamic-extrusion-compensation). The line that would request calibration
from the file (`;M1002 set_flag extrude_cali_flag=1`) is commented out in
Bambu's own template: **the sliced file offers the block; the printer's
stored calibration state decides.** SlicePad ships the template
unmodified, so it cooperates with the printer's calibration exactly the
way Bambu Studio's files do.

### End G-code

Full text: `App/SlicePad/Resources/end_gcode.txt`. Ends with the AMS
unload sentinel bracket — every stock print unloads its filament:

```gcode
M620 S255
T255
M621 S255
```

### Layer change

One comment line (`; layer num/total_layer_count: {layer_num+1}/[total_layer_count]`)
plus the writer's `M73` progress lines.

### The change-filament template (not used by SlicePad v1)

`change_filament_gcode` (6,120 chars, header `A1mini 20251031`, in
`Resources/change_filament_gcode.txt`) only ever runs on a toolchange.
Its structure: park over the poop chute (X 180 on the mini) → the
`M620 S<new>A … T<new> … M621 S<new>A` bracket (firmware cuts, retracts,
feeds) → up to four pulsatile flush blocks driven by
`flush_length_1…4` with wiper passes. SlicePad v1 is single-filament per
print, so it never emits it — it is bundled for completeness/future use.

## 3. AMS lite specifics

- **Every AMS load/unload is a bracket**: `M620 S<n>A … T<n> … M621 S<n>A`.
  `T<n>` inside is the actual feed/cut/load trigger. `S255/T255` is the
  unload/empty sentinel. An unclosed bracket is a known hang risk.
- **Slot numbering in the file is 0-based**: UI slot 1–4 → `S0–S3`.
  Slot 1 is `M620 S0A`, never `S1A`.
- The `S` value is the *project filament index*. Which physical AMS lite
  tray (A1–A4) that maps to is decided at print-send time (`M620 M`
  enables the mapping; Bambu Studio/Handy or the printer's AMS Mapping
  screen supply it). A standalone file like SlicePad's therefore uses
  the honest **identity mapping: slot k → S = k−1**, and the printer's
  mapping screen remains the final authority.
- `M620.1 E F<flush feedrate> T<temp>`: flush feedrate =
  `volumetric_speed / 2.4053 × 60` — how the templates convert a
  volumetric speed to an E feedrate in mm/min.
- Other dialect residents: `M412 S1` runout detection, `M620.3 W1`
  tangle detection, `M400` waits, `G380 S2/S3` Z-endstop moves,
  `M960` lamp/laser control (not AMS).

## 4. Flow — the numbers that keep extrusion honest

Source: filament profiles under `resources/profiles/BBL/filament/`
(inherits resolved), plus Bambu Studio source
(`src/libslic3r/GCode.cpp`, `PrintConfig.cpp`).

| Filament (A1M, 0.4 nozzle) | Max volumetric speed | Flow ratio |
|---|---|---|
| **Bambu PLA Basic** | **21 mm³/s** (`Bambu PLA Basic @base.json`) | 0.98 |
| Generic PLA | 12 mm³/s (`fdm_filament_pla.json`) | 0.98 |
| Bambu PLA Matte | 22 mm³/s | — |
| Bambu PETG Basic | 13 mm³/s | 0.94 |
| Bambu PETG HF | 18 mm³/s | 0.94 |
| Generic PETG | 8 mm³/s | 0.95 |

- There is **no hotend/machine volumetric ceiling** in the profiles —
  the per-filament cap is the binding constraint (the extruder's own
  30 mm/s E limit ≈ 72 mm³/s never binds).
- **Bambu Studio enforces the cap in the slicer**, not on the printer:
  `speed = min(speed, cap / mm³-per-mm)` (GCode.cpp ≈6654, ≈7840).
  Worked example from the profiles: an inner wall asking 300 mm/s at
  0.45 × 0.2 mm is clamped to ≈233 mm/s under the 21 cap, ≈133 under 12.
  SlicePad implements the identical clamp per extrusion move, with the
  cap and flow ratio taken from the selected preset (flow ratio is
  baked into the emitted E values; the start template resets
  `M221 S100`).
- **Pressure advance: Bambu files emit none.** No profile in the entire
  BBL tree sets `pressure_advance`; every `M900` emission site in
  GCode.cpp is guarded `!is_BBL_Printer()` with the comment
  `//BBS: never use for Bambu Printer`, and the config tooltips say
  "Useless for Bambu Printer". Flow dynamics are the printer's own
  calibration (§2). SlicePad likewise emits no `M900`.
- ABS/ASA have **no A1M profiles at all** (open-frame printer) — SlicePad
  v1 offers PLA and PETG presets only.

## 5. Output format — why `.gcode.3mf`, not plain `.gcode`

This was the decision the whole project hinged on. Evidence:

- Plain `.gcode` **does** print from the microSD root, started on the
  printer's touchscreen (Bambu's A1 mini spec lists "Printable file
  format: G-Code"; the wiki SD guide requires card root, FAT32). But:
  no preview image, and **no AMS**.
- Firsthand controlled test on an A1 mini (Bambu forum, user Dill,
  byte-identical G-code in both containers): the `.gcode.3mf` asks
  "Use AMS", loads and prints; the plain `.gcode` shows no AMS option —
  "AMS does nothing … printer stops reporting error because no filament
  is loaded" — despite the same `M620/M621` commands being present.
  His isolation: *"the crucial file for AMS functionality is
  `Metadata/slice_info.config`. If this file doesn't contain the full
  list of used filaments, printer will not change the filament,
  regardless of what is in the GCODE."*
- Remote start agrees: the LAN `project_file` command requires the 3MF
  container; the legacy `gcode_file` command is reported non-functional
  on A-series.
- On the LAN path the header blocks stop being cosmetic — a
  hardware-verified A1 mini project (fw 01.08.01.00) found a missing
  `HEADER_BLOCK` hangs the job on "Preparing" and a missing
  `CONFIG_BLOCK` gets it silently cancelled. A missing **thumbnail**,
  by contrast, is printable on every path (the PNGs are display-only;
  the XML references to them are what must exist).

**Verdict: SlicePad's primary output is `.gcode.3mf`** containing:

| Entry | Content |
|---|---|
| `Metadata/plate_1.gcode` | Full Bambu-dialect G-code (§2: header, config, executable blocks, M73, footer) |
| `Metadata/plate_1.gcode.md5` | Uppercase MD5 of the G-code |
| `Metadata/slice_info.config` | Client headers, plate index, A1 mini `printer_model_id`, `prediction` (s), `weight` (g), and one `<filament>` entry per used filament — **the AMS gatekeeper** |
| `Metadata/model_settings.config` | Plate entry: `plater_id=1`, filament map fields, `gcode_file`, thumbnail/plate-json references |
| `Metadata/project_settings.config` | Full A1 mini profile JSON (generated from the Bambu Studio profile chain, not hand-minimised) |
| `Metadata/plate_1.json` | Plate bbox, bed type, filament colour/id, first extruder |
| `Metadata/plate_1.png`, `plate_1_small.png` | Top-view render of the model (display only) |
| `[Content_Types].xml`, `_rels/.rels`, `3D/3dmodel.model` | Standard 3MF scaffolding |

A plain `.gcode` export is also offered, labelled in the UI
**"External spool only — no AMS, start from the printer screen"**,
because that is all the evidence supports for it.

## 6. WiFi, accounts, and AMS sync — the verdict

Researched from Bambu Studio's device code, Bambu's wiki (LAN Only Mode,
Developer Mode, third-party authorization pages) and the community
protocol implementations (OpenBambuAPI, pybambu).

**No Bambu account is needed — for anything.** The printer-local
credential trio is all SlicePad ever asks for, all read off the
printer's own screen and stored in the iOS Keychain:

- printer **IP** (or SSDP discovery), **serial number** (exact case),
  and the 8-character **LAN access code**.

| Capability | Needs | Conditions |
|---|---|---|
| Read status + AMS lite filaments | MQTT/TLS :8883, user `bblp` + access code | Works even in cloud mode (Bambu exempts MQTT status from Authorization Control) |
| Upload a file | Implicit FTPS :990, `bblp` + access code | Developer Mode on current A-series firmware |
| Start a print | FTPS upload + MQTT `project_file` | **LAN Only Mode + Developer Mode** — otherwise third-party starts are rejected unless routed through Bambu Connect (which *does* need a cloud login, and has no iPad app) |

Protocol facts implemented:
- **Discovery**: SSDP on UDP 1990/2021, `239.255.255.250:2021`,
  ST `urn:bambulab-com:device:3dprinter:1`; `USN` = serial,
  `Location` = IP, `DevModel` = `N1` (A1 mini). Manual IP entry always
  available.
- **MQTT**: topics `device/<serial>/report` (subscribe, QoS 1) and
  `device/<serial>/request` (publish). A `pushall` request gets a full
  status dump; the A1 otherwise sends **deltas** that must be
  deep-merged. Pushall is rate-limited (don't spam it; ~5 min cadence
  is the community-observed safe floor on A1/P1-class machines).
  Wrong-case serial = connects but silently receives nothing.
- **AMS data**: the report's `print.ams` object — `ams[0].tray[0…3]`
  with `tray_type`, `tray_color` (RRGGBBAA), `tray_info_idx` (preset
  name), presence from `tray_exist_bits` (a **hex** bitfield),
  `tray_now` (254 = external spool, 255 = none). RFID-equipped Bambu
  spools identify type/colour automatically.
  **Remaining % is NOT reported on the AMS lite** (pybambu gates the
  feature to non-A1 models) — SlicePad shows type/colour/preset for
  the 4 trays and never promises a remaining-amount figure.
- **Upload + start**: FTPS to the microSD (Bambu Studio's target is
  `/cache/`), then MQTT `project_file` referencing
  `Metadata/plate_1.gcode` inside the `.gcode.3mf`. There are no
  command acknowledgements — a launch is confirmed by watching the
  report stream change state.
- Trade-offs, stated in the app: LAN Only Mode disables Bambu Handy
  and Print History; Developer Mode disconnects the printer from
  Bambu Cloud while enabled. One-time caveat: Developer Mode needs
  firmware ≥ 01.05.00.00, so a printer on older firmware needs one
  update first. Joining WiFi itself is done on the printer's screen,
  no account involved.

⚠️ One honestly-unresolved item: the exact `project_file` `url`
dialect and `ams_mapping` encoding have several attested forms on A1
hardware. SlicePad implements the safest documented form first; which
form the user's printer accepts can only be settled by one test launch on
that machine (see §8).

## 7. How SlicePad uses all of this

- Templates: the printer-facing G-code is Bambu's own A1 mini text,
  rendered by a placeholder engine supporting exactly the constructs
  the templates use (`{if}/{elsif}/{else}/{endif}`, `{expr}`,
  `[name]`, array indexing, arithmetic/comparison/boolean ops).
  Single-filament bindings: `initial_extruder = slot`, temps from the
  selected preset, `curr_bed_type = "Textured PEI Plate"`.
- Slicing: STL (binary + ASCII) → per-layer loop stitching → 2+
  perimeters → grid infill / solid top-bottom shells → skirt/brim.
  Defaults are the 0.20 mm Standard @BBL A1M profile's numbers (§1).
- Flow: per-move volumetric clamp, Bambu's own formula (§4).
- Time estimate: an acceleration-aware trapezoidal planner over the
  final emitted moves (the same class of estimator Bambu Studio runs;
  its figure is shown in the UI and written to the header like
  Studio's `; model printing time:`).
- Printer tab: SSDP discovery → MQTT status + AMS lite trays → FTPS
  upload → `project_file` start. Access code in Keychain only; never
  in the repo, never in chat, no account sign-in anywhere in the app.

## 8. Owed device tests (nothing here substitutes for the user's printer)

1. `.gcode.3mf` single-filament print via AMS lite slot 1 (the core
   claim of §5).
2. WiFi send + `project_file` start on the user's firmware — settles the
   `url`/`ams_mapping` dialect question in §6.
3. Plain `.gcode`, external spool, touchscreen start (the fallback's
   claim).
4. Time-estimate accuracy vs the printer's own countdown.

Until test 1 passes, the README says — truthfully — that printer
verification is pending.

## Sources

- Bambu Studio (open source): github.com/bambulab/BambuStudio —
  `resources/profiles/BBL/{machine,process,filament}/…` (A1 mini
  templates and profile chains as cited inline),
  `src/libslic3r/GCode.cpp` (volumetric clamp, M900 guard),
  `src/libslic3r/PrintConfig.cpp`, `src/slic3r/GUI/DeviceManager.cpp` +
  `DevFilaSystem.cpp` (MQTT/AMS parsing).
- Bambu Lab wiki: A1 print-from-SD guide, microSD FAQ, internally
  sliced files, LAN Only Mode, Developer Mode, third-party
  authorization pages; A1 mini tech specs (bambulab.com).
- A1 mini Quick Start Guide (AMS mapping screen).
- Community (labelled as such where used): OpenBambuAPI (protocol +
  AMS JSON), pybambu / ha-bambulab (AMS lite behaviour, remain gating),
  BambuPlotter (A1 mini header-block requirements, fw 01.08.01.00),
  bambox (3MF metadata optionality), Bambu forum AMS A/B test
  (user Dill).
