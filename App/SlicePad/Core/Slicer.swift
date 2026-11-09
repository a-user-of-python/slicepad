// Slicer.swift — SlicePad slicer core: mesh slicing, perimeters, infill,
// extrusion/flow-clamped G-code generation in Bambu A1 mini dialect.
//
// Pipeline: centre the mesh on the 180x180 plate (XY centre 90,90, z-min
// to 0), intersect triangles per layer, stitch segments into loops,
// classify outers/holes by containment depth, offset perimeters, hatch
// infill clipped by the innermost perimeter, then emit moves with
// absolute E (M82) and Bambu's volumetric flow clamp applied to every
// extrusion move: speed = min(speed, cap / (lineWidth * layerHeight))
// (Bambu Studio GCode.cpp: "cap speed with max_volumetric_speed anyway").

import Foundation

// MARK: - Plane slicing: triangles -> segments -> stitched loops

private struct SegKey: Hashable { var x: Int; var y: Int }
private func segKey(_ p: Vec2) -> SegKey {
    SegKey(x: Int((p.x * 10000).rounded()), y: Int((p.y * 10000).rounded()))
}

/// Intersect all triangles with the plane z = planeZ, returning segments.
private func sliceSegments(triangles: [Triangle], planeZ: Double) -> [(Vec2, Vec2)] {
    var segments: [(Vec2, Vec2)] = []
    for tri in triangles {
        let pts = [tri.a, tri.b, tri.c]
        let d = pts.map { $0.z - planeZ }
        var hits: [Vec2] = []
        for e in 0..<3 {
            let p = pts[e], q = pts[(e + 1) % 3]
            let dp = d[e], dq = d[(e + 1) % 3]
            if (dp < 0 && dq >= 0) || (dq < 0 && dp >= 0) {
                let t = dp / (dp - dq)
                hits.append(Vec2(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
            }
        }
        // Dedupe hits that coincide (vertex exactly on the plane).
        var uniq: [Vec2] = []
        for h in hits {
            if !uniq.contains(where: { $0.distance(to: h) < 1e-9 }) { uniq.append(h) }
        }
        if uniq.count == 2 {
            segments.append((uniq[0], uniq[1]))
        }
    }
    return segments
}

/// Stitch loose segments into closed loops. Endpoints are matched through
/// a 1e-4 mm quantised hash, with a 3x3 neighbourhood search so endpoints
/// computed from opposite sides of a shared edge still join.
private func stitchLoops(segments: [(Vec2, Vec2)]) -> [[Vec2]] {
    struct Seg { var p1: Vec2; var p2: Vec2; var k1: SegKey; var k2: SegKey; var used: Bool }
    var segs: [Seg] = []
    var byKey: [SegKey: [Int]] = [:]
    for (a, b) in segments {
        let ka = segKey(a), kb = segKey(b)
        if ka == kb { continue } // degenerate
        let idx = segs.count
        segs.append(Seg(p1: a, p2: b, k1: ka, k2: kb, used: false))
        byKey[ka, default: []].append(idx)
        byKey[kb, default: []].append(idx)
    }
    func incident(to key: SegKey) -> [Int] {
        var out: [Int] = []
        for dx in -1...1 {
            for dy in -1...1 {
                if let list = byKey[SegKey(x: key.x + dx, y: key.y + dy)] { out.append(contentsOf: list) }
            }
        }
        return out
    }
    func keyMatches(_ a: SegKey, _ b: SegKey) -> Bool { abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 }

    var loops: [[Vec2]] = []
    for startIdx in segs.indices {
        if segs[startIdx].used { continue }
        segs[startIdx].used = true
        var loop: [Vec2] = [segs[startIdx].p1, segs[startIdx].p2]
        let startKey = segs[startIdx].k1
        var curKey = segs[startIdx].k2
        var closed = false
        var safety = 0
        while safety < 100000 {
            safety += 1
            if keyMatches(curKey, startKey) { closed = true; break }
            var advanced = false
            for candIdx in incident(to: curKey) {
                if segs[candIdx].used { continue }
                let s = segs[candIdx]
                if keyMatches(s.k1, curKey) {
                    segs[candIdx].used = true
                    loop.append(s.p2)
                    curKey = s.k2
                    advanced = true
                    break
                } else if keyMatches(s.k2, curKey) {
                    segs[candIdx].used = true
                    loop.append(s.p1)
                    curKey = s.k1
                    advanced = true
                    break
                }
            }
            if !advanced { break }
        }
        if closed {
            let cleaned = cleanLoop(loop)
            if cleaned.count >= 3 && abs(polygonSignedArea(cleaned)) > 0.01 {
                loops.append(cleaned)
            }
        }
    }
    return loops
}

/// Classify loops into outers and holes by containment nesting depth:
/// even depth = outer, odd = hole. Windings are normalised to
/// outer = CCW, hole = CW.
private func classifyLoops(_ loops: [[Vec2]]) -> (outers: [[Vec2]], holes: [[Vec2]]) {
    var outers: [[Vec2]] = []
    var holes: [[Vec2]] = []
    for i in loops.indices {
        guard let probe = loops[i].first else { continue }
        var depth = 0
        for j in loops.indices where j != i {
            if pointInPolygon(probe, loops[j]) { depth += 1 }
        }
        var loop = loops[i]
        let area = polygonSignedArea(loop)
        if depth % 2 == 0 {
            if area < 0 { loop.reverse() }
            outers.append(loop)
        } else {
            if area > 0 { loop.reverse() }
            holes.append(loop)
        }
    }
    return (outers, holes)
}

// MARK: - G-code builder (absolute E, retraction, flow clamp)

private final class GBuilder {
    let settings: SliceSettings
    var lines: [String] = []
    var preview: [PreviewPath] = []
    var curX: Double? = nil
    var curY: Double? = nil
    var curZ: Double = 0
    var curE: Double = 0
    var retracted = false
    var filamentMM: Double = 0

    init(settings: SliceSettings) { self.settings = settings }

    var travelFeed: Double { min(settings.travelSpeed, 500.0) * 60.0 }
    var retractFeed: Double { settings.retractionSpeed * 60.0 }

    func drain() -> String {
        let s = lines.joined(separator: "\n")
        lines = []
        return s
    }

    func retract() {
        guard !retracted, settings.retractionLength > 0 else { return }
        curE -= settings.retractionLength
        lines.append("G1 E\(spE(curE)) F\(spNum(retractFeed, 2))")
        retracted = true
    }
    func deretract() {
        guard retracted else { return }
        curE += settings.retractionLength
        lines.append("G1 E\(spE(curE)) F\(spNum(retractFeed, 2))")
        retracted = false
    }

    /// Travel move; retracts first when the XY distance exceeds 2 mm
    /// (or when forced, e.g. at layer change).
    func travelTo(x: Double, y: Double, z: Double, forceRetract: Bool = false) {
        var dist = 0.0
        if let cx = curX, let cy = curY {
            dist = ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot()
        } else {
            dist = 999 // first move of the print: always emit, no retract needed yet
        }
        if (forceRetract || dist > 2.0) && curX != nil { retract() }
        if curX == x && curY == y && curZ == z { return }
        lines.append("G1 X\(spCoord(x)) Y\(spCoord(y)) Z\(spCoord(z)) F\(spNum(travelFeed, 2))")
        curX = x; curY = y; curZ = z
    }

    /// One extrusion segment with the mandatory volumetric flow clamp:
    /// if lineWidth * layerHeight * speed exceeds the filament cap, the
    /// speed is reduced to cap / (lineWidth * layerHeight).
    func extrudeTo(x: Double, y: Double, width: Double, height: Double, speed requested: Double) {
        guard let cx = curX, let cy = curY else { return }
        let dist = ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot()
        if dist < 1e-9 { return }
        deretract()
        var speed = requested
        let cap = settings.effMaxVolumetric
        if cap > 0 && width * height > 0 && width * height * speed > cap {
            speed = cap / (width * height)
        }
        let dE = dist * width * height * settings.effFlowRatio / filamentAreaMM2
        curE += dE
        filamentMM += dE
        lines.append("G1 X\(spCoord(x)) Y\(spCoord(y)) E\(spE(curE)) F\(spNum(speed * 60.0, 2))")
        curX = x; curY = y
    }

    /// Emit a whole polyline (optionally closed) as extrusion moves and
    /// record it as a preview path.
    func extrudePath(_ points: [Vec2], close: Bool, z: Double, width: Double, height: Double,
                     speed: Double, kind: PreviewKind) {
        guard let first = points.first else { return }
        travelTo(x: first.x, y: first.y, z: z)
        var verts = points
        if close && points.count > 1 { verts.append(points[0]) }
        for p in verts.dropFirst() {
            extrudeTo(x: p.x, y: p.y, width: width, height: height, speed: speed)
        }
        preview.append(PreviewPath(kind: kind, points: verts.map { Vec3(x: $0.x, y: $0.y, z: z) }))
    }
}

// MARK: - Template bindings

private func makeBindings(settings: SliceSettings, bboxMin: Vec2, bboxSize: Vec2,
                          center: Vec2, maxZ: Double, totalLayers: Int,
                          layerNum: Int, layerZ: Double) -> [String: TV] {
    let s = settings.slotIndex
    let p = settings.preset
    // Effective (override-aware) values for the four overridable fields.
    let nozzleTemp = settings.effNozzleTemp
    let bedTemp = settings.effBedTemp
    let maxVol = settings.effMaxVolumetric
    // Single-filament job: the value arrays are indexed by extruder index
    // in Bambu's model. SlicePad's one preset is repeated for all four AMS
    // slots so indexing by the selected slot always resolves.
    func rep(_ v: TV) -> TV { .arr(Array(repeating: v, count: 4)) }
    let outerVol = min(maxVol, settings.outerWallSpeed * settings.lineWidth * settings.firstLayerHeight)
    return [
        "initial_extruder": .num(Double(s)),
        "initial_no_support_extruder": .num(Double(s)),
        "current_extruder": .num(Double(s)),
        "next_extruder": .num(255),
        "previous_extruder": .num(255),
        "nozzle_diameter": .num(0.4),
        "nozzle_temperature": rep(.num(Double(nozzleTemp))),
        "nozzle_temperature_initial_layer": rep(.num(Double(nozzleTemp))),
        "bed_temperature": rep(.num(Double(bedTemp))),
        "bed_temperature_initial_layer": rep(.num(Double(bedTemp))),
        "bed_temperature_initial_layer_single": .num(Double(bedTemp)),
        "filament_type": rep(.str(p.type)),
        "flush_temperatures": rep(.num(Double(nozzleTemp))),
        "flush_volumetric_speeds": rep(.num(maxVol)),
        "outer_wall_volumetric_speed": .num(outerVol),
        "curr_bed_type": .str("Textured PEI Plate"),
        "first_layer_print_min": .arr([.num(bboxMin.x), .num(bboxMin.y)]),
        "first_layer_print_size": .arr([.num(bboxSize.x), .num(bboxSize.y)]),
        "first_layer_center_no_wipe_tower": .arr([.num(center.x), .num(center.y)]),
        "max_layer_z": .num(maxZ),
        "layer_num": .num(Double(layerNum)),
        "layer_z": .num(layerZ),
        "total_layer_count": .num(Double(totalLayers)),
        "spiral_mode": .bool(false),
        "print_sequence": .str("by layer"),
        "activate_air_filtration": rep(.bool(false)),
        "support_air_filtration": .bool(false),
        "during_print_exhaust_fan_speed_num": rep(.num(100)),
        "flush_length": .num(0),
        "flush_length_1": .num(0),
        "flush_length_2": .num(0),
        "flush_length_3": .num(0),
        "flush_length_4": .num(0),
        "long_retractions_when_cut": rep(.bool(false)),
        "retraction_distances_when_cut": rep(.num(18)),
        "old_filament_temp": .num(Double(nozzleTemp)),
        "new_filament_temp": .num(Double(nozzleTemp)),
        "old_retract_length_toolchange": .num(2),
        "new_retract_length_toolchange": .num(2),
        "x_after_toolchange": .num(0),
        "y_after_toolchange": .num(0),
        "z_after_toolchange": .num(0),
        "in_head_wrap_detect_zone": .bool(false),
        "initial_layer_print_height": .num(settings.firstLayerHeight),
        "default_acceleration": .num(6000),
        "initial_layer_acceleration": .num(500),
    ]
}

private func formatDuration(_ seconds: Double) -> String {
    // Bambu header style: "29m 19s" under an hour, "1h 2m 3s" above it.
    let t = max(0, Int(seconds.rounded()))
    if t >= 3600 { return "\(t / 3600)h \((t % 3600) / 60)m \(t % 60)s" }
    return "\((t % 3600) / 60)m \(t % 60)s"
}

// MARK: - Main entry point

/// Slice a mesh into a complete Bambu-dialect G-code program for the
/// A1 mini (180x180x180). The mesh is centred on the plate; the Core
/// assumes it fits (the app layer warns when it does not).
public func sliceModel(mesh: Mesh, settings: SliceSettings, templates: TemplateSet) -> SliceResult {
    let rawMin = mesh.minB, rawMax = mesh.maxB
    let offX = 90.0 - (rawMin.x + rawMax.x) / 2.0
    let offY = 90.0 - (rawMin.y + rawMax.y) / 2.0
    let offZ = -rawMin.z
    let tris: [Triangle] = mesh.triangles.map {
        Triangle(a: Vec3(x: $0.a.x + offX, y: $0.a.y + offY, z: $0.a.z + offZ),
                 b: Vec3(x: $0.b.x + offX, y: $0.b.y + offY, z: $0.b.z + offZ),
                 c: Vec3(x: $0.c.x + offX, y: $0.c.y + offY, z: $0.c.z + offZ),
                 normal: $0.normal)
    }
    let modelMin = Vec2(x: rawMin.x + offX, y: rawMin.y + offY)
    let modelMax = Vec2(x: rawMax.x + offX, y: rawMax.y + offY)
    let modelSize = Vec2(x: modelMax.x - modelMin.x, y: modelMax.y - modelMin.y)
    let modelCenter = Vec2(x: (modelMin.x + modelMax.x) / 2, y: (modelMin.y + modelMax.y) / 2)
    let height = max(rawMax.z - rawMin.z, 0.0)

    // Layer top heights: first layer, then layerHeight steps.
    var tops: [Double] = []
    if height > 0 {
        var t = min(settings.firstLayerHeight, height)
        tops.append(t)
        while t < height - 1e-9 {
            t = min(t + settings.layerHeight, height)
            tops.append(t)
        }
    }
    let layerCount = tops.count
    let builder = GBuilder(settings: settings)
    var chunks: [String] = []

    let wo = settings.lineWidth
    let wi = settings.innerLineWidth

    for li in 0..<layerCount {
        let top = tops[li]
        let prevTop = li == 0 ? 0.0 : tops[li - 1]
        let lh = top - prevTop
        let planeZ = prevTop + lh / 2.0
        let isFirst = li == 0
        let isTop = li == layerCount - 1
        let isSolid = li < settings.bottomLayers || li >= layerCount - settings.topLayers

        let segments = sliceSegments(triangles: tris, planeZ: planeZ)
        let loops = stitchLoops(segments: segments)
        let (outers, holes) = classifyLoops(loops)
        let allLoops = outers + holes

        if li > 0 { builder.retract() } // always retract before a layer change

        // Skirt (first layer only): loose loops around every outer loop.
        if isFirst && settings.skirtLoops > 0 {
            for s in 0..<settings.skirtLoops {
                let grow = 2.0 + wo / 2.0 + Double(s) * wo
                for loop in outers {
                    for ring in offsetLoop(loop, shrink: -grow) {
                        builder.extrudePath(ring, close: true, z: top, width: wo, height: lh,
                                            speed: settings.firstLayerSpeed, kind: .skirtOrBrim)
                    }
                }
            }
        }
        // Brim (first layer only): concentric rings out to brimWidth,
        // printed outermost-first so the last ring touches the part.
        if isFirst && settings.brimWidth > 0 {
            let ringCount = max(1, Int((settings.brimWidth / wo).rounded(.up)))
            for loop in outers {
                var rings: [[Vec2]] = []
                for k in 0..<ringCount {
                    rings.append(contentsOf: offsetLoop(loop, shrink: -(wo / 2.0 + Double(k) * wo)))
                }
                for ring in rings.reversed() {
                    builder.extrudePath(ring, close: true, z: top, width: wo, height: lh,
                                        speed: settings.firstLayerSpeed, kind: .skirtOrBrim)
                }
            }
        }

        // Perimeters. Wall k centreline distance from the boundary:
        // outer wall wo/2; inner wall k: wo + (k-1)*wi + wi/2.
        // Print order is inner walls first, then the outer wall.
        var innerWalls: [(loop: [Vec2], width: Double)] = []
        var outerWalls: [(loop: [Vec2], width: Double)] = []
        var infillRegion: [[Vec2]] = []
        // Inner edge of the innermost wall = infill boundary distance.
        let infillInset: Double
        if settings.wallCount <= 0 { infillInset = wo / 2.0 }
        else if settings.wallCount == 1 { infillInset = wo }
        else { infillInset = wo + Double(settings.wallCount - 1) * wi }

        for loop in allLoops {
            for k in 0..<max(settings.wallCount, 0) {
                let centre = k == 0 ? wo / 2.0 : wo + Double(k - 1) * wi + wi / 2.0
                let width = k == 0 ? wo : wi
                for piece in offsetLoop(loop, shrink: centre) {
                    if k == 0 { outerWalls.append((piece, width)) } else { innerWalls.append((piece, width)) }
                }
            }
            infillRegion.append(contentsOf: offsetLoop(loop, shrink: infillInset))
        }

        let innerSpeed = isFirst ? settings.firstLayerSpeed : settings.innerWallSpeed
        let outerSpeed = isFirst ? settings.firstLayerSpeed : settings.outerWallSpeed
        for w in innerWalls {
            builder.extrudePath(w.loop, close: true, z: top, width: w.width, height: lh,
                                speed: innerSpeed, kind: .innerWall)
        }
        for w in outerWalls {
            builder.extrudePath(w.loop, close: true, z: top, width: w.width, height: lh,
                                speed: outerSpeed, kind: .outerWall)
        }

        // Infill.
        if !infillRegion.isEmpty {
            let angle = li % 2 == 0 ? 45.0 : -45.0
            if isSolid {
                let speed = isFirst ? settings.firstLayerSpeed
                    : (isTop ? settings.topSurfaceSpeed : settings.solidInfillSpeed)
                let kind: PreviewKind = isTop ? .topSurface : .solidInfill
                var segs = clipHatchLines(loops: infillRegion, angleDegrees: angle, spacing: wo)
                for idx in segs.indices where idx % 2 == 1 { segs[idx] = (segs[idx].1, segs[idx].0) }
                for seg in segs {
                    builder.extrudePath([seg.0, seg.1], close: false, z: top, width: wi, height: lh,
                                        speed: speed, kind: kind)
                }
            } else if settings.infillPercent > 0 {
                let spacing = wi * 100.0 / settings.infillPercent
                let speed = isFirst ? settings.firstLayerSpeed : settings.infillSpeed
                for passAngle in [angle, angle + 90.0] {
                    var segs = clipHatchLines(loops: infillRegion, angleDegrees: passAngle, spacing: spacing)
                    for idx in segs.indices where idx % 2 == 1 { segs[idx] = (segs[idx].1, segs[idx].0) }
                    for seg in segs {
                        builder.extrudePath([seg.0, seg.1], close: false, z: top, width: wi, height: lh,
                                            speed: speed, kind: .infill)
                    }
                }
            }
        }
        chunks.append(builder.drain())
    }

    let filamentMM = builder.filamentMM
    let filamentGrams = filamentMM * filamentAreaMM2 * settings.preset.density / 1000.0
    let preview = builder.preview

    // Render the templates (layer-change is rendered per layer below).
    func bindings(layerNum: Int, layerZ: Double) -> [String: TV] {
        makeBindings(settings: settings, bboxMin: modelMin, bboxSize: modelSize,
                     center: modelCenter, maxZ: height, totalLayers: layerCount,
                     layerNum: layerNum, layerZ: layerZ)
    }
    let startRendered = renderTemplate(templates.start, bindings: bindings(layerNum: 0, layerZ: tops.first ?? 0)).text
    let filamentStartRendered = renderTemplate(templates.filamentStart, bindings: bindings(layerNum: 0, layerZ: tops.first ?? 0)).text
    let filamentEndRendered = renderTemplate(templates.filamentEnd, bindings: bindings(layerNum: 0, layerZ: height)).text
    let endRendered = renderTemplate(templates.end, bindings: bindings(layerNum: 0, layerZ: height)).text
    var layerHeaders: [String] = []
    for li in 0..<layerCount {
        layerHeaders.append(renderTemplate(templates.layerChange, bindings: bindings(layerNum: li, layerZ: tops[li])).text)
    }

    // Two-pass time accounting: estimate the start/end sequences and each
    // layer chunk, so M73 remaining-minutes and the header total agree
    // with the final estimate over the whole emitted file.
    let estStart = estimateTimeSeconds(gcode: startRendered + "\n" + filamentStartRendered)
    var chunkEst: [Double] = []
    for li in 0..<layerCount {
        chunkEst.append(estimateTimeSeconds(gcode: layerHeaders[li] + "\n" + chunks[li]))
    }
    let estEnd = estimateTimeSeconds(gcode: filamentEndRendered + "\n" + endRendered)
    let totalEst = estStart + chunkEst.reduce(0, +) + estEnd

    let modelName = mesh.name.isEmpty ? "model" : mesh.name
        .replacingOccurrences(of: ";", with: "")
        .replacingOccurrences(of: "\n", with: " ")

    var out: [String] = []
    // (1) HEADER_BLOCK
    out.append("; HEADER_BLOCK_START")
    out.append("; generated by SlicePad 1.0")
    out.append("; model printing time: \(formatDuration(totalEst)); total estimated time: \(formatDuration(totalEst))")
    out.append("; total layer number: \(layerCount)")
    out.append("; total filament length [mm] : \(spNum(filamentMM, 2))")
    out.append("; total filament volume [cm3] : \(spNum(filamentMM * filamentAreaMM2 / 1000.0, 2))")
    out.append("; total filament weight [g] : \(spNum(filamentGrams, 2))")
    out.append("; model label id: 1")
    out.append("; filament_density: \(spNum(settings.preset.density, 4))")
    out.append("; filament_diameter: 1.75")
    out.append("; filament_type: \(settings.preset.type)")
    out.append("; max_z_height: \(spNum(height, 2))")
    out.append("; HEADER_BLOCK_END")
    // (2) CONFIG_BLOCK — the settings actually used.
    out.append("; CONFIG_BLOCK_START")
    let cfg: [(String, String)] = [
        ("printer_model", "Bambu Lab A1 mini"),
        ("nozzle_diameter", "0.4"),
        ("layer_height", spNum(settings.layerHeight, 4)),
        ("initial_layer_print_height", spNum(settings.firstLayerHeight, 4)),
        ("line_width", spNum(settings.lineWidth, 4)),
        ("wall_loops", String(settings.wallCount)),
        ("top_shell_layers", String(settings.topLayers)),
        ("bottom_shell_layers", String(settings.bottomLayers)),
        ("sparse_infill_density", "\(spNum(settings.infillPercent, 2))%"),
        ("sparse_infill_pattern", "grid"),
        ("outer_wall_speed", spNum(settings.outerWallSpeed, 2)),
        ("inner_wall_speed", spNum(settings.innerWallSpeed, 2)),
        ("sparse_infill_speed", spNum(settings.infillSpeed, 2)),
        ("internal_solid_infill_speed", spNum(settings.solidInfillSpeed, 2)),
        ("top_surface_speed", spNum(settings.topSurfaceSpeed, 2)),
        ("initial_layer_speed", spNum(settings.firstLayerSpeed, 2)),
        ("travel_speed", spNum(min(settings.travelSpeed, 500.0), 2)),
        ("retraction_length", spNum(settings.retractionLength, 4)),
        ("retraction_speed", spNum(settings.retractionSpeed, 2)),
        ("nozzle_temperature", String(settings.effNozzleTemp)),
        ("nozzle_temperature_initial_layer", String(settings.effNozzleTemp)),
        ("textured_plate_temp", String(settings.effBedTemp)),
        ("textured_plate_temp_initial_layer", String(settings.effBedTemp)),
        ("filament_type", settings.preset.type),
        ("filament_flow_ratio", spNum(settings.effFlowRatio, 4)),
        ("filament_max_volumetric_speed", spNum(settings.effMaxVolumetric, 4)),
        ("filament_density", spNum(settings.preset.density, 4)),
        ("filament_diameter", "1.75"),
        ("curr_bed_type", "Textured PEI Plate"),
    ]
    for (k, v) in cfg { out.append("; \(k) = \(v)") }
    out.append("; CONFIG_BLOCK_END")
    // (3) EXECUTABLE_BLOCK
    out.append("; EXECUTABLE_BLOCK_START")
    out.append(startRendered)
    out.append(filamentStartRendered)
    // The start template leaves the extruder in relative mode (M83);
    // the sliced body uses absolute E.
    out.append("M82")
    out.append("G92 E0")
    out.append("M624 \(modelName)")
    var elapsed = estStart
    for li in 0..<layerCount {
        out.append(layerHeaders[li])
        let pct = totalEst > 0 ? min(100, max(0, Int(elapsed / totalEst * 100.0))) : 0
        let remMin = max(0, Int((totalEst - elapsed) / 60.0))
        out.append("M73 P\(pct) R\(remMin)")
        out.append(chunks[li])
        elapsed += chunkEst[li]
    }
    out.append("M625")
    out.append(filamentEndRendered)
    out.append(endRendered)
    out.append("; EXECUTABLE_BLOCK_END")
    // Footer (Bambu convention).
    let cm3 = filamentMM * filamentAreaMM2 / 1000.0
    out.append("; filament used [mm] = \(spNum(filamentMM, 2))")
    out.append("; filament used [cm3] = \(spNum(cm3, 2))")
    out.append("; filament used [g] = \(spNum(filamentGrams, 2))")
    out.append("; total filament used [g] = \(spNum(filamentGrams, 2))")
    out.append("; model printing time: \(formatDuration(totalEst)); total estimated time: \(formatDuration(totalEst))")

    return SliceResult(gcode: out.joined(separator: "\n") + "\n",
                       estimatedSeconds: totalEst,
                       filamentUsedMM: filamentMM,
                       filamentUsedGrams: filamentGrams,
                       layerCount: layerCount,
                       maxZ: height,
                       preview: preview)
}
