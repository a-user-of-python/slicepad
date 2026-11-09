// STL.swift — SlicePad slicer core: triangle mesh type and STL loading.
// Supports binary STL (84-byte header + uint32 triangle count) and
// ASCII STL ("solid" ... "facet" ... "vertex" lines). Foundation only.

import Foundation

public struct Triangle: Equatable {
    public var a: Vec3
    public var b: Vec3
    public var c: Vec3
    public var normal: Vec3
    public init(a: Vec3, b: Vec3, c: Vec3, normal: Vec3) {
        self.a = a; self.b = b; self.c = c; self.normal = normal
    }
    /// Geometric (unnormalised cross product) normal from the winding.
    public static func faceNormal(a: Vec3, b: Vec3, c: Vec3) -> Vec3 {
        (b - a).cross(c - a)
    }
}

public struct Mesh {
    public var triangles: [Triangle]
    public var name: String
    public init(triangles: [Triangle], name: String) {
        self.triangles = triangles
        self.name = name
    }
    public var minB: Vec3 {
        guard var lo = triangles.first?.a else { return Vec3() }
        for t in triangles {
            for p in [t.a, t.b, t.c] {
                lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y); lo.z = min(lo.z, p.z)
            }
        }
        return lo
    }
    public var maxB: Vec3 {
        guard var hi = triangles.first?.a else { return Vec3() }
        for t in triangles {
            for p in [t.a, t.b, t.c] {
                hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y); hi.z = max(hi.z, p.z)
            }
        }
        return hi
    }
}

public enum STLError: Error {
    case emptyData
    case malformed
}

private func readUInt32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

private func readFloat32LE(_ bytes: [UInt8], _ offset: Int) -> Double {
    Double(Float32(bitPattern: readUInt32LE(bytes, offset)))
}

/// Load an STL file (binary or ASCII) into a Mesh.
/// Binary layout is preferred whenever the byte count matches the
/// 84 + count*50 layout exactly, because some binary files begin with
/// the text "solid" in their header.
public func loadSTL(data: Data, name: String) throws -> Mesh {
    if data.isEmpty { throw STLError.emptyData }
    let bytes = [UInt8](data)

    // Binary STL?
    if bytes.count >= 84 {
        let count = Int(readUInt32LE(bytes, 80))
        if count > 0 && 84 + count * 50 == bytes.count {
            var tris: [Triangle] = []
            tris.reserveCapacity(count)
            var off = 84
            for _ in 0..<count {
                let n = Vec3(x: readFloat32LE(bytes, off), y: readFloat32LE(bytes, off + 4), z: readFloat32LE(bytes, off + 8))
                let a = Vec3(x: readFloat32LE(bytes, off + 12), y: readFloat32LE(bytes, off + 16), z: readFloat32LE(bytes, off + 20))
                let b = Vec3(x: readFloat32LE(bytes, off + 24), y: readFloat32LE(bytes, off + 28), z: readFloat32LE(bytes, off + 32))
                let c = Vec3(x: readFloat32LE(bytes, off + 36), y: readFloat32LE(bytes, off + 40), z: readFloat32LE(bytes, off + 44))
                // Trust the stored normal when it is non-zero; else compute.
                let normal = (n.length > 0) ? n : Triangle.faceNormal(a: a, b: b, c: c)
                tris.append(Triangle(a: a, b: b, c: c, normal: normal))
                off += 50
            }
            return Mesh(triangles: tris, name: name)
        }
    }

    // ASCII STL: collect "vertex x y z" lines, group every three into a facet.
    guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
        throw STLError.malformed
    }
    var verts: [Vec3] = []
    for rawLine in text.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("vertex") else { continue }
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 4, let x = Double(parts[1]), let y = Double(parts[2]), let z = Double(parts[3]) else {
            continue
        }
        verts.append(Vec3(x: x, y: y, z: z))
    }
    guard verts.count >= 3 else { throw STLError.malformed }
    var tris: [Triangle] = []
    var i = 0
    while i + 2 < verts.count {
        let a = verts[i], b = verts[i + 1], c = verts[i + 2]
        tris.append(Triangle(a: a, b: b, c: c, normal: Triangle.faceNormal(a: a, b: b, c: c)))
        i += 3
    }
    if tris.isEmpty { throw STLError.malformed }
    return Mesh(triangles: tris, name: name)
}
