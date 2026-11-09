// Polygon.swift — SlicePad slicer core: 2D polygon operations.
// Loops are [Vec2] polylines without a duplicated closing point.
// Winding convention after classification: outer loops CCW (positive
// signed area), hole loops CW (negative signed area).

import Foundation

/// Signed area: positive for CCW, negative for CW.
public func polygonSignedArea(_ poly: [Vec2]) -> Double {
    guard poly.count >= 3 else { return 0 }
    var a = 0.0
    for i in 0..<poly.count {
        let p = poly[i], q = poly[(i + 1) % poly.count]
        a += p.x * q.y - q.x * p.y
    }
    return a / 2
}

/// Even-odd point-in-polygon test (ray casting).
public func pointInPolygon(_ pt: Vec2, _ poly: [Vec2]) -> Bool {
    guard poly.count >= 3 else { return false }
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let pi = poly[i], pj = poly[j]
        if (pi.y > pt.y) != (pj.y > pt.y) {
            let xInt = (pj.x - pi.x) * (pt.y - pi.y) / (pj.y - pi.y) + pi.x
            if pt.x < xInt { inside = !inside }
        }
        j = i
    }
    return inside
}

/// Proper segment intersection point, or nil. Intersections at shared
/// endpoints (within `eps` of a vertex parameter) are not reported, so
/// adjacent polygon edges never count as crossing.
func segmentCrossing(_ p1: Vec2, _ p2: Vec2, _ p3: Vec2, _ p4: Vec2) -> Vec2? {
    let d1 = p2 - p1, d2 = p4 - p3
    let denom = d1.cross(d2)
    if abs(denom) < 1e-12 { return nil }
    let t = (p3 - p1).cross(d2) / denom
    let u = (p3 - p1).cross(d1) / denom
    let eps = 1e-9
    guard t > eps, t < 1 - eps, u > eps, u < 1 - eps else { return nil }
    return p1 + d1 * t
}

/// Remove consecutive duplicate / near-duplicate points (and a duplicated
/// closing point).
func cleanLoop(_ poly: [Vec2]) -> [Vec2] {
    var out: [Vec2] = []
    for p in poly {
        if let last = out.last, last.distance(to: p) < 1e-7 { continue }
        out.append(p)
    }
    if out.count > 1, let f = out.first, let l = out.last, f.distance(to: l) < 1e-7 {
        out.removeLast()
    }
    return out
}

/// Split a possibly self-intersecting loop into simple loops.
/// Strategy: find the first proper crossing between two non-adjacent
/// edges, cut both edges at the crossing point, and recurse on the two
/// resulting loops. Depth-capped; degenerate slivers are dropped by the
/// caller's area filter.
func splitSimpleLoops(_ poly: [Vec2], depth: Int) -> [[Vec2]] {
    let p = cleanLoop(poly)
    guard p.count >= 3, depth < 6 else { return p.count >= 3 ? [p] : [] }
    let n = p.count
    for i in 0..<n {
        let a1 = p[i], a2 = p[(i + 1) % n]
        for j in (i + 1)..<n {
            if j == i + 1 { continue }                 // adjacent
            if i == 0 && j == n - 1 { continue }       // wrap-adjacent
            let b1 = p[j], b2 = p[(j + 1) % n]
            if let x = segmentCrossing(a1, a2, b1, b2) {
                // Loop 1: x -> p[i+1] ... p[j] -> x
                var l1: [Vec2] = [x]
                var k = i + 1
                while k <= j { l1.append(p[k % n]); k += 1 }
                // Loop 2: x -> p[j+1] ... p[i] -> x
                var l2: [Vec2] = [x]
                k = j + 1
                while k <= j + (n - (j - i)) {
                    // walk from j+1 around through 0..i
                    l2.append(p[k % n])
                    if k % n == i { break }
                    k += 1
                }
                return splitSimpleLoops(l1, depth: depth + 1) + splitSimpleLoops(l2, depth: depth + 1)
            }
        }
    }
    return [p]
}

/// Offset a loop, shrinking the material region by `shrink` mm
/// (negative values grow it). Works for both windings: the shift is
/// applied along each edge's left normal scaled by the winding sign, so
/// CCW outers move inward and CW holes expand into the void.
/// Returns 0, 1 or more simple loops; loops whose area sign flipped or
/// whose |area| < 0.05 mm^2 are dropped (the offset collapsed them).
public func offsetLoop(_ loop: [Vec2], shrink: Double) -> [[Vec2]] {
    let src = cleanLoop(loop)
    guard src.count >= 3 else { return [] }
    let area = polygonSignedArea(src)
    guard area != 0 else { return [] }
    let sign = area > 0 ? 1.0 : -1.0
    let n = src.count

    // Offset line for edge i: point = src[i] + leftNormal_i * (shrink*sign),
    // direction = edge direction.
    func edgeLine(_ i: Int) -> (point: Vec2, dir: Vec2) {
        let p = src[i], q = src[(i + 1) % n]
        let d = q - p
        let len = d.length
        guard len > 0 else { return (p, Vec2(x: 1, y: 0)) }
        let leftNormal = Vec2(x: -d.y / len, y: d.x / len)
        return (p + leftNormal * (shrink * sign), d)
    }

    var raw: [Vec2] = []
    for i in 0..<n {
        let prev = edgeLine((i + n - 1) % n)
        let curr = edgeLine(i)
        let denom = prev.dir.cross(curr.dir)
        if abs(denom) < 1e-10 {
            // Near-parallel consecutive edges: both offset lines pass
            // (nearly) through one point — the vertex shifted along the
            // shared left normal, which is exact in the parallel limit.
            raw.append(vertexOffset(src: src, i: i, shrink: shrink, sign: sign))
        } else {
            let t = (curr.point - prev.point).cross(curr.dir) / denom
            raw.append(prev.point + prev.dir * t)
        }
    }
    let cleaned = cleanLoop(raw)
    guard cleaned.count >= 3 else { return [] }
    var result: [[Vec2]] = []
    for part in splitSimpleLoops(cleaned, depth: 0) {
        let a = polygonSignedArea(part)
        if (a > 0) == (area > 0) && abs(a) >= 0.05 {
            result.append(part)
        }
    }
    return result
}

/// Vertex pushed along the angle bisector by the offset lines of its two
/// edges — used only for the (near-)parallel consecutive-edge case, where
/// both offset lines pass (nearly) through this single point.
private func vertexOffset(src: [Vec2], i: Int, shrink: Double, sign: Double) -> Vec2 {
    let n = src.count
    func leftNormal(ofEdge i: Int) -> Vec2 {
        let p = src[i], q = src[(i + 1) % n]
        let d = q - p
        let len = max(d.length, 1e-12)
        return Vec2(x: -d.y / len, y: d.x / len)
    }
    let n1 = leftNormal(ofEdge: (i + n - 1) % n)
    // For parallel edges both edge normals agree, so this is exact there.
    return src[i] + n1 * (shrink * sign)
}

/// Clip a set of parallel hatch lines to the region bounded by `loops`
/// (outers + holes together) using scanline even-odd pairing: every
/// intersection of the line with any loop edge is collected, sorted along
/// the line, and consecutive pairs form the inside segments.
public func clipHatchLines(loops: [[Vec2]], angleDegrees: Double, spacing: Double) -> [(Vec2, Vec2)] {
    guard spacing > 0, !loops.isEmpty else { return [] }
    let rad = angleDegrees * Double.pi / 180.0
    let dir = Vec2(x: cos(rad), y: sin(rad))
    let nrm = Vec2(x: -dir.y, y: dir.x)
    var cMin = Double.greatestFiniteMagnitude
    var cMax = -Double.greatestFiniteMagnitude
    for loop in loops {
        for p in loop {
            let c = p.dot(nrm)
            cMin = min(cMin, c); cMax = max(cMax, c)
        }
    }
    guard cMin <= cMax else { return [] }
    var segments: [(Vec2, Vec2)] = []
    var c = (cMin / spacing).rounded(.up) * spacing
    // Guard against a pathological line count.
    var guardCount = 0
    while c <= cMax + 1e-9 && guardCount < 100000 {
        guardCount += 1
        var ts: [Double] = []
        for loop in loops {
            let m = loop.count
            for i in 0..<m {
                let p = loop[i], q = loop[(i + 1) % m]
                let cp = p.dot(nrm) - c
                let cq = q.dot(nrm) - c
                if cp == 0 && cq == 0 { continue } // edge lies on the line
                if (cp < 0 && cq >= 0) || (cq < 0 && cp >= 0) {
                    let f = cp / (cp - cq)
                    let hit = p + (q - p) * f
                    ts.append(hit.dot(dir))
                }
            }
        }
        ts.sort()
        // Dedupe intersections that coincide (shared vertices).
        var uniq: [Double] = []
        for t in ts {
            if let last = uniq.last, abs(t - last) < 1e-7 { continue }
            uniq.append(t)
        }
        var k = 0
        while k + 1 < uniq.count {
            let t0 = uniq[k], t1 = uniq[k + 1]
            if t1 - t0 > 0.1 {
                let base = nrm * c
                segments.append((base + dir * t0, base + dir * t1))
            }
            k += 2
        }
        c += spacing
    }
    return segments
}
