// main.swift — SlicePad slicer Core test harness.
// Usage: main <repo-root>
// Loads the verbatim Bambu templates from App/SlicePad/Resources, slices a
// 20 mm cube and a hollow frame, audits the emitted G-code, checks the
// .gcode.3mf package, and prints ASSERT PASS/FAIL lines. Exit code is
// non-zero when any assert fails.

import Foundation
import CryptoKit
#if os(Linux)
import Glibc
#endif

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("ASSERT \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { failures += 1 }
}
func info(_ msg: String) { print("INFO \(msg)") }

guard CommandLine.arguments.count >= 2 else {
    print("usage: harness <repo-root>")
    exit(2)
}
let root = CommandLine.arguments[1]

func loadText(_ rel: String) -> String {
    let path = root + "/" + rel
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("FATAL cannot read \(path)")
        exit(2)
    }
    return s
}

let templates = TemplateSet(
    start: loadText("App/SlicePad/Resources/start_gcode.txt"),
    end: loadText("App/SlicePad/Resources/end_gcode.txt"),
    layerChange: loadText("App/SlicePad/Resources/layer_change_gcode.txt"),
    filamentStart: loadText("App/SlicePad/Resources/filament_start_gcode.txt"),
    filamentEnd: loadText("App/SlicePad/Resources/filament_end_gcode.txt"))

let fixturePath = root + "/Tests/Harness/project_settings_fixture.json"
let projectSettingsJSON = FileManager.default.fileExists(atPath: fixturePath)
    ? loadText("Tests/Harness/project_settings_fixture.json") : "{}"

// MARK: - Test geometry (generated in code)

func addBox(_ tris: inout [Triangle], _ mn: Vec3, _ mx: Vec3) {
    let v = [
        Vec3(x: mn.x, y: mn.y, z: mn.z), Vec3(x: mx.x, y: mn.y, z: mn.z),
        Vec3(x: mx.x, y: mx.y, z: mn.z), Vec3(x: mn.x, y: mx.y, z: mn.z),
        Vec3(x: mn.x, y: mn.y, z: mx.z), Vec3(x: mx.x, y: mn.y, z: mx.z),
        Vec3(x: mx.x, y: mx.y, z: mx.z), Vec3(x: mn.x, y: mx.y, z: mx.z),
    ]
    let faces = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7),
                 (0, 1, 5), (0, 5, 4), (2, 3, 7), (2, 7, 6),
                 (0, 4, 7), (0, 7, 3), (1, 2, 6), (1, 6, 5)]
    for f in faces {
        let a = v[f.0], b = v[f.1], c = v[f.2]
        tris.append(Triangle(a: a, b: b, c: c, normal: Triangle.faceNormal(a: a, b: b, c: c)))
    }
}

var cubeTris: [Triangle] = []
addBox(&cubeTris, Vec3(x: 0, y: 0, z: 0), Vec3(x: 20, y: 20, z: 20))
let cube = Mesh(triangles: cubeTris, name: "cube20.stl")

// Hollow frame: 30x30x4 plate with a 14x14 through-hole, built from
// 4 boxes (separate shells are fine for the slicer). After centring, the
// hole spans (83,83)-(97,97) on the plate.
var frameTris: [Triangle] = []
addBox(&frameTris, Vec3(x: 0, y: 0, z: 0), Vec3(x: 8, y: 30, z: 4))
addBox(&frameTris, Vec3(x: 22, y: 0, z: 0), Vec3(x: 30, y: 30, z: 4))
addBox(&frameTris, Vec3(x: 8, y: 0, z: 0), Vec3(x: 22, y: 8, z: 4))
addBox(&frameTris, Vec3(x: 8, y: 22, z: 0), Vec3(x: 22, y: 30, z: 4))
let frame = Mesh(triangles: frameTris, name: "frame.stl")

// MARK: - G-code body audit helpers
// Audits are scoped to the object body between the M624 / M625 markers:
// the machine start/end templates legitimately move off-plate (wiper at
// X-13.5, purge at Y-2.5) and extrude purge filament under firmware
// control, so plate bounds and the volumetric clamp apply to the
// slicer's own moves, which live between M624 and M625.

struct BodyAudit {
    var boundsOK = true
    var maxFlow = 0.0
    var segments: [(z: Double, x0: Double, y0: Double, x1: Double, y1: Double)] = []
}

func wordVal(_ tokens: [String], _ letter: Character) -> Double? {
    for t in tokens where t.first == letter && t.count > 1 {
        return Double(t.dropFirst())
    }
    return nil
}

func auditBody(gcode: String) -> BodyAudit {
    var result = BodyAudit()
    let lines = gcode.components(separatedBy: "\n")
    guard let startIdx = lines.firstIndex(where: { $0.hasPrefix("M624") }),
          let endIdx = lines.firstIndex(where: { $0.hasPrefix("M625") }),
          endIdx > startIdx else {
        result.boundsOK = false
        return result
    }
    var x = 0.0, y = 0.0, z = 0.0, e = 0.0, feed = 0.0
    for line in lines[(startIdx + 1)..<endIdx] {
        var code = line
        if let semi = code.firstIndex(of: ";") { code = String(code[..<semi]) }
        let tokens = code.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let cmd = tokens.first, cmd == "G0" || cmd == "G1" else { continue }
        if let f = wordVal(tokens, "F") { feed = f }
        let nx = wordVal(tokens, "X") ?? x
        let ny = wordVal(tokens, "Y") ?? y
        let nz = wordVal(tokens, "Z") ?? z
        var dE = 0.0
        if let ev = wordVal(tokens, "E") { dE = ev - e; e = ev }
        let dist = ((nx - x) * (nx - x) + (ny - y) * (ny - y)).squareRoot()
        if dE > 0 {
            // Extrusion endpoint must be on the plate, at a sane Z.
            if nx < -0.001 || nx > 180.001 || ny < -0.001 || ny > 180.001 || nz > 180.001 {
                result.boundsOK = false
            }
            if dist > 0.001 && feed > 0 {
                let flow = (dE * 2.4053) / dist * (feed / 60.0)
                result.maxFlow = max(result.maxFlow, flow)
                result.segments.append((z: nz, x0: x, y0: y, x1: nx, y1: ny))
            }
        }
        x = nx; y = ny; z = nz
    }
    return result
}

// MARK: - Cube slice (default settings)

let settings = SliceSettings()
let cubeResult = sliceModel(mesh: cube, settings: settings, templates: templates)
let gcode = cubeResult.gcode

check("layerCount_cube_100", cubeResult.layerCount == 100, "got \(cubeResult.layerCount)")

let audit = auditBody(gcode: gcode)
check("extrusion_endpoints_on_plate", audit.boundsOK)
check("volumetric_clamp_pla_basic", audit.maxFlow <= 21.0 + 0.35, "max flow \(audit.maxFlow)")

check("start_has_M620_S0A", gcode.contains("M620 S0A"))
var slot2Settings = SliceSettings()
slot2Settings.slotIndex = 2
let slot2Result = sliceModel(mesh: cube, settings: slot2Settings, templates: templates)
check("slot2_has_M620_S2A", slot2Result.gcode.contains("M620 S2A"))
check("end_has_M620_S255", gcode.contains("M620 S255"))
check("no_template_leftovers", !gcode.contains("{") && !gcode.contains("}")
      && !gcode.contains("{if") && !gcode.contains("[total_layer_count]"))

check("temps_in_start", gcode.contains("M140 S65") && gcode.contains("220"),
      "bed M140 S65 and nozzle 220 expected")

check("estimate_sane", cubeResult.estimatedSeconds >= 240 && cubeResult.estimatedSeconds <= 5400,
      "SlicePad estimate \(Int(cubeResult.estimatedSeconds)) s")
// Golden reference (Bambu Studio 2.9.1, same cube/profiles): prediction
// 1760 s, 1257.57 mm / ~3.81 g. Printed for comparison, not asserted —
// SlicePad's estimator is a simpler accel model over its own move list.
info("cube estimate: SlicePad \(Int(cubeResult.estimatedSeconds)) s vs Bambu Studio golden 1760 s")
info("cube filament: SlicePad \(String(format: "%.2f", cubeResult.filamentUsedGrams)) g (\(String(format: "%.1f", cubeResult.filamentUsedMM)) mm) vs golden ~3.81 g (1257.57 mm)")

check("filament_used_range", cubeResult.filamentUsedGrams > 3 && cubeResult.filamentUsedGrams < 20,
      "got \(cubeResult.filamentUsedGrams) g")

// MARK: - Overrides (settings API addition)

var ovSettings = SliceSettings()
ovSettings.nozzleTempOverride = 230
ovSettings.bedTempOverride = 60
ovSettings.flowRatioOverride = 0.95
ovSettings.maxVolumetricOverride = 10
let ovResult = sliceModel(mesh: cube, settings: ovSettings, templates: templates)
let ovAudit = auditBody(gcode: ovResult.gcode)
check("override_temps_rendered", ovResult.gcode.contains("; nozzle_temperature = 230")
      && ovResult.gcode.contains("M140 S60"))
check("override_volumetric_clamp", ovAudit.maxFlow <= 10.0 * 0.95 + 0.35,
      "max flow \(ovAudit.maxFlow)")

// MARK: - 3MF package

let thumb = makeThumbnailPNG(mesh: cube, size: 128)
check("thumbnail_is_png", thumb.count > 100 && thumb[0] == 0x89 && thumb[1] == 0x50,
      "\(thumb.count) bytes")

let threeMF = buildThreeMF(gcode: gcode, modelName: "cube20.stl", settings: settings,
                           estimatedSeconds: cubeResult.estimatedSeconds,
                           filamentUsedGrams: cubeResult.filamentUsedGrams,
                           layerCount: cubeResult.layerCount,
                           bboxMin: Vec2(x: 80, y: 80), bboxMax: Vec2(x: 100, y: 100),
                           thumbnailPNG: thumb, projectSettingsJSON: projectSettingsJSON)

// Extract stored ZIP entries by scanning local file headers.
func u16(_ d: Data, _ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) }
func u32(_ d: Data, _ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) | (Int(d[o + 2]) << 16) | (Int(d[o + 3]) << 24) }
var entries: [String: Data] = [:]
var off = 0
while off + 30 <= threeMF.count && u32(threeMF, off) == 0x0403_4B50 {
    let size = u32(threeMF, off + 18)
    let nameLen = u16(threeMF, off + 26)
    let extraLen = u16(threeMF, off + 28)
    let name = String(data: threeMF[(off + 30)..<(off + 30 + nameLen)], encoding: .utf8) ?? ""
    let dataStart = off + 30 + nameLen + extraLen
    entries[name] = threeMF[dataStart..<(dataStart + size)]
    off = dataStart + size
}
check("threemf_gcode_roundtrip", entries["Metadata/plate_1.gcode"] == Data(gcode.utf8))
let md5Expected = Insecure.MD5.hash(data: Data(gcode.utf8)).map { String(format: "%02X", $0) }.joined()
let md5Actual = entries["Metadata/plate_1.gcode.md5"].flatMap { String(data: $0, encoding: .utf8) }
check("threemf_md5_uppercase", md5Actual == md5Expected, "file: \(md5Actual ?? "missing")")
let sliceInfo = entries["Metadata/slice_info.config"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
check("threemf_slice_info", sliceInfo.contains("<filament") && sliceInfo.contains("prediction"))

// MARK: - Frame slice (hole must stay empty)

let frameResult = sliceModel(mesh: frame, settings: settings, templates: templates)
check("frame_layers", frameResult.layerCount > 0, "got \(frameResult.layerCount)")
let frameAudit = auditBody(gcode: frameResult.gcode)
// Layer index 2 (third layer, solid) tops out at z = 0.6.
var holeOK = true
for seg in frameAudit.segments where abs(seg.z - 0.6) < 0.01 {
    let mx = (seg.x0 + seg.x1) / 2, my = (seg.y0 + seg.y1) / 2
    if mx > 84 && mx < 96 && my > 84 && my < 96 { holeOK = false }
}
check("frame_hole_respected", holeOK)

print(failures == 0 ? "HARNESS RESULT: PASS" : "HARNESS RESULT: FAIL (\(failures) failures)")
exit(failures == 0 ? 0 : 1)
