// TimeEstimator.swift — SlicePad slicer core: print-time estimation.
//
// The estimator runs over the FINAL emitted G-code string (including the
// rendered machine start/end templates, which contain real G1 moves with
// feedrates), so the reported "model printing time" covers the same move
// stream Bambu's own figure covers.
//
// Motion model (documented, deliberately simple — an accel-aware estimate,
// not a firmware planner):
//   * Every G0/G1/G2/G3 move is a trapezoid: it accelerates from its entry
//     speed to its feedrate and decelerates to its exit speed.
//   * Entry speed of a move = min(previous move's exit speed, feedrate).
//   * Exit speed = min(feedrate, next feedrate * cornerFactor), where
//     cornerFactor = max(0.25, cos(turnAngle/2)) from the direction change
//     between consecutive moves; the last move exits at 0. This is a
//     junction-speed approximation in the spirit of the machine's 9 mm/s
//     jerk setting without simulating the full planner queue.
//   * Accelerations: 5000 mm/s^2 for extrusion (print) moves, 9000 mm/s^2
//     for travel moves (A1 mini machine_max_acceleration_travel), 500 mm/s^2
//     for Z-only moves. Pure-E moves use the print acceleration.
//   * M400 S<n> / M400 P<ms> and G4 dwells add their dwell time.
//   * Temperature waits (M109/M190) have no modelled duration and add 0.

import Foundation

private struct EstMove {
    var distance: Double   // mm (XYZ length, chord for arcs, |dE| for E-only)
    var feed: Double       // mm/s
    var accel: Double      // mm/s^2
    var dirX: Double, dirY: Double, dirZ: Double // unit direction, or 0 for E-only
    var hasDir: Bool
}

/// Parse one G-code word like "X-13.5" from a token; returns nil if absent.
private func wordValue(_ tokens: [String], _ letter: Character) -> Double? {
    for t in tokens {
        guard let first = t.first, first == letter, t.count > 1 else { continue }
        return Double(t.dropFirst())
    }
    return nil
}

/// Parser + planner state carried between chunks. A G-code program is a
/// single modal stream (positions, feedrate, absolute/relative modes and
/// the planner's exit speed all persist across any split), so chunked
/// estimation MUST thread this state — restarting it per chunk makes the
/// first absolute-E move of every chunk measure its delta from E0, which
/// invents kilometres of phantom filament motion (found the hard way:
/// per-layer chunks summed to ~6x the whole-file estimate).
public struct EstimatorState {
    public var posX = 0.0, posY = 0.0, posZ = 0.0, posE = 0.0
    public var feedMMMin = 0.0
    public var absoluteXYZ = true
    public var absoluteE = true
    public var prevExit = 0.0
    public init() {}
}

/// Estimate the execution time (seconds) of a complete G-code program.
public func estimateTimeSeconds(gcode: String) -> Double {
    estimateTimeSeconds(gcode: gcode, initialState: EstimatorState()).seconds
}

/// Estimate one chunk of a program, threading modal state in and out.
public func estimateTimeSeconds(gcode: String, initialState: EstimatorState) -> (seconds: Double, endState: EstimatorState) {
    var state = initialState
    var moves: [EstMove] = []
    var dwell: Double = 0

    var posX = state.posX, posY = state.posY, posZ = state.posZ, posE = state.posE
    var feedMMMin = state.feedMMMin
    var absoluteXYZ = state.absoluteXYZ
    var absoluteE = state.absoluteE

    for rawLine in gcode.components(separatedBy: "\n") {
        var line = rawLine
        if let semi = line.firstIndex(of: ";") { line = String(line[..<semi]) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let cmd = tokens.first else { continue }

        switch cmd {
        case "G90": absoluteXYZ = true; absoluteE = true
        case "G91": absoluteXYZ = false; absoluteE = false
        case "M82": absoluteE = true
        case "M83": absoluteE = false
        case "G92":
            if let v = wordValue(tokens, "X") { posX = v }
            if let v = wordValue(tokens, "Y") { posY = v }
            if let v = wordValue(tokens, "Z") { posZ = v }
            if let v = wordValue(tokens, "E") { posE = v }
        case "M400":
            if let s = wordValue(tokens, "S") { dwell += s }
            if let p = wordValue(tokens, "P") { dwell += p / 1000.0 }
        case "G4":
            if let s = wordValue(tokens, "S") { dwell += s }
            if let p = wordValue(tokens, "P") { dwell += p / 1000.0 }
        case "G0", "G1", "G2", "G3":
            if let f = wordValue(tokens, "F") { feedMMMin = f }
            let nx = wordValue(tokens, "X").map { absoluteXYZ ? $0 : posX + $0 } ?? posX
            let ny = wordValue(tokens, "Y").map { absoluteXYZ ? $0 : posY + $0 } ?? posY
            let nz = wordValue(tokens, "Z").map { absoluteXYZ ? $0 : posZ + $0 } ?? posZ
            var dE = 0.0
            if let e = wordValue(tokens, "E") {
                dE = absoluteE ? e - posE : e
                posE = absoluteE ? e : posE + e
            }
            let dx = nx - posX, dy = ny - posY, dz = nz - posZ
            let dXYZ = (dx * dx + dy * dy + dz * dz).squareRoot()
            posX = nx; posY = ny; posZ = nz
            let feed = feedMMMin / 60.0
            if feed <= 0 { continue }
            if dXYZ > 1e-9 {
                let isTravel = dE == 0
                let zOnly = abs(dx) < 1e-12 && abs(dy) < 1e-12
                let accel = zOnly ? 500.0 : (isTravel ? 9000.0 : 5000.0)
                moves.append(EstMove(distance: dXYZ, feed: feed, accel: accel,
                                     dirX: dx / dXYZ, dirY: dy / dXYZ, dirZ: dz / dXYZ, hasDir: true))
            } else if abs(dE) > 1e-9 {
                moves.append(EstMove(distance: abs(dE), feed: feed, accel: 5000.0,
                                     dirX: 0, dirY: 0, dirZ: 0, hasDir: false))
            }
        default:
            break
        }
    }

    // Trapezoidal pass with junction-limited exit speeds.
    var total = dwell
    var prevExit = state.prevExit
    for i in 0..<moves.count {
        let m = moves[i]
        var exitSpeed = 0.0
        if i + 1 < moves.count {
            let next = moves[i + 1]
            var cornerFactor = 1.0
            if m.hasDir && next.hasDir {
                let cosTurn = max(-1.0, min(1.0, m.dirX * next.dirX + m.dirY * next.dirY + m.dirZ * next.dirZ))
                let turnAngle = acos(cosTurn)
                cornerFactor = max(0.25, cos(turnAngle / 2))
            }
            exitSpeed = min(m.feed, next.feed * cornerFactor)
        }
        let entry = min(prevExit, m.feed)
        let exitV = min(exitSpeed, m.feed)
        let a = m.accel
        let d = m.distance
        let dAccel = entry < m.feed ? (m.feed * m.feed - entry * entry) / (2 * a) : 0
        let dDecel = exitV < m.feed ? (m.feed * m.feed - exitV * exitV) / (2 * a) : 0
        if dAccel + dDecel >= d {
            // Triangular profile: never reaches feedrate.
            let vPeak = ((2 * a * d + entry * entry + exitV * exitV) / 2).squareRoot()
            total += (vPeak - entry) / a + (vPeak - exitV) / a
        } else {
            total += (m.feed - entry) / a + (m.feed - exitV) / a + (d - dAccel - dDecel) / m.feed
        }
        prevExit = exitV
    }
    state.posX = posX; state.posY = posY; state.posZ = posZ; state.posE = posE
    state.feedMMMin = feedMMMin
    state.absoluteXYZ = absoluteXYZ; state.absoluteE = absoluteE
    state.prevExit = prevExit
    return (total, state)
}
