// Vec.swift — SlicePad slicer core: basic 2D/3D vector types and shared
// numeric helpers. Foundation only; no UI frameworks.

import Foundation

public struct Vec2: Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public init() { self.init(x: 0, y: 0) }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(x: a.x * s, y: a.y * s) }
    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    public var length: Double { (x * x + y * y).squareRoot() }
    public func distance(to o: Vec2) -> Double { (self - o).length }
}

public struct Vec3: Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    public init() { self.init(x: 0, y: 0, z: 0) }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(x: a.x * s, y: a.y * s, z: a.z * s) }
    public func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
    public func cross(_ o: Vec3) -> Vec3 {
        Vec3(x: y * o.z - z * o.y, y: z * o.x - x * o.z, z: x * o.y - y * o.x)
    }
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public func distance(to o: Vec3) -> Double { (self - o).length }
    public var xy: Vec2 { Vec2(x: x, y: y) }
}

/// Cross-sectional area of 1.75 mm filament in mm^2.
/// pi * 0.875^2 = 2.40528...; Bambu templates use the rounded constant 2.4053
/// in expressions such as {flush_volumetric_speeds[i]/2.4053*60}.
public let filamentAreaMM2: Double = Double.pi * 0.875 * 0.875

/// Bambu-style number formatting: integers print without a decimal point,
/// other values print with up to `maxDecimals` decimals, trailing zeros cut.
func spNum(_ v: Double, _ maxDecimals: Int = 4) -> String {
    if v.isNaN || v.isInfinite { return "0" }
    if v == v.rounded() && abs(v) < 1e12 {
        return String(Int(v))
    }
    let fmt = "%." + String(maxDecimals) + "f"
    var s = String(format: fmt, v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    if s == "-0" { s = "0" }
    return s
}

/// G-code coordinate formatting (3 decimals max).
func spCoord(_ v: Double) -> String { spNum(v, 3) }
/// G-code extrusion (E axis) formatting (5 decimals max).
func spE(_ v: Double) -> String { spNum(v, 5) }

// MARK: - Checksums shared by the PNG writer and the ZIP writer.

/// CRC-32 (IEEE 802.3, polynomial 0xEDB88320), as used by PNG and ZIP.
func spCRC32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in bytes {
        crc ^= UInt32(b)
        for _ in 0..<8 {
            if crc & 1 != 0 { crc = (crc >> 1) ^ 0xEDB8_8320 } else { crc >>= 1 }
        }
    }
    return crc ^ 0xFFFF_FFFF
}

/// Adler-32, as used by the zlib stream inside PNG IDAT chunks.
func spAdler32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    for byte in bytes {
        a = (a + UInt32(byte)) % 65521
        b = (b + a) % 65521
    }
    return (b << 16) | a
}
