import Foundation

// MARK: - Local STL file listing
//
// SlicePad's primary import path is an in-app browser over the app's own
// Documents folder: the system document picker is unreliable on some
// installs, so the app never depends on it. This helper is pure
// Foundation so the host harness can test the listing rules off-device:
// every .stl under the given root — including the Inbox subfolder where
// iOS drops "Open in" copies — newest first, hidden files skipped.

struct LocalSTLFile: Equatable {
    /// Full URL of the file.
    let url: URL
    /// Display name (last path component).
    let name: String
    /// Path relative to the scanned root ("Inbox/part.stl", "part.stl").
    let relativePath: String
    /// File size in bytes (0 when unknown).
    let sizeBytes: Int64
    /// Last modification date (distant past when unknown).
    let modified: Date
}

/// Recursively lists every STL file under `root`. Extension matching is
/// case-insensitive (".STL" counts). Sorted newest first, ties broken by
/// relative path so the order is stable.
func listLocalSTLFiles(in root: URL, fileManager: FileManager = .default) -> [LocalSTLFile] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard let enumerator = fileManager.enumerator(at: root,
                                                  includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles]) else {
        return []
    }
    let rootPath = root.standardizedFileURL.path
    var found: [LocalSTLFile] = []
    for case let url as URL in enumerator {
        guard url.pathExtension.lowercased() == "stl" else { continue }
        let values = try? url.resourceValues(forKeys: Set(keys))
        if let isFile = values?.isRegularFile, !isFile { continue }
        let path = url.standardizedFileURL.path
        let rel = path.hasPrefix(rootPath + "/")
            ? String(path.dropFirst(rootPath.count + 1))
            : url.lastPathComponent
        found.append(LocalSTLFile(url: url,
                                  name: url.lastPathComponent,
                                  relativePath: rel,
                                  sizeBytes: Int64(values?.fileSize ?? 0),
                                  modified: values?.contentModificationDate ?? .distantPast))
    }
    return found.sorted {
        if $0.modified != $1.modified { return $0.modified > $1.modified }
        return $0.relativePath < $1.relativePath
    }
}

// MARK: - Example file seeding
//
// An app's Files folder (On My iPad → SlicePad) does not materialise for
// sideloaded installs until the app has actually written into its
// Documents directory — and on a fresh install there is also nothing to
// slice yet. So on every launch the app calls
// `seedExampleSTLIfNeeded(in:)`: it creates Documents if needed and,
// only when no STL exists anywhere under it (Inbox included), writes a
// small sample cube. Idempotent and cheap: one directory enumeration,
// and once the user has any STL of their own the seed never comes back.

/// File name of the seeded sample model.
let exampleSTLFileName = "Example Cube.stl"

/// A valid binary STL of a 20 mm cube sitting on the build plate
/// (x/y centred on the origin is unnecessary — the slicer centres the
/// model on the plate; z starts at 0). Built from 12 triangles with
/// outward winding and matching facet normals.
func exampleCubeSTLData(side: Double = 20) -> Data {
    let s = Float(side)
    // Corner shorthand: 0 = (0,0,0), 1 = (s,s,s).
    let v000 = (Float(0), Float(0), Float(0))
    let v100 = (s, Float(0), Float(0))
    let v110 = (s, s, Float(0))
    let v010 = (Float(0), s, Float(0))
    let v001 = (Float(0), Float(0), s)
    let v101 = (s, Float(0), s)
    let v111 = (s, s, s)
    let v011 = (Float(0), s, s)
    typealias P = (Float, Float, Float)
    // Two triangles per face, wound counter-clockwise seen from outside.
    let faces: [(P, P, P)] = [
        // bottom (z = 0, normal -z)
        (v000, v110, v100), (v000, v010, v110),
        // top (z = s, normal +z)
        (v001, v101, v111), (v001, v111, v011),
        // front (y = 0, normal -y)
        (v000, v100, v101), (v000, v101, v001),
        // back (y = s, normal +y)
        (v010, v111, v110), (v010, v011, v111),
        // left (x = 0, normal -x)
        (v000, v001, v011), (v000, v011, v010),
        // right (x = s, normal +x)
        (v100, v110, v111), (v100, v111, v101),
    ]
    func normal(_ a: P, _ b: P, _ c: P) -> P {
        let ux = b.0 - a.0, uy = b.1 - a.1, uz = b.2 - a.2
        let vx = c.0 - a.0, vy = c.1 - a.1, vz = c.2 - a.2
        var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx
        let len = sqrt(nx * nx + ny * ny + nz * nz)
        if len > 0 { nx /= len; ny /= len; nz /= len }
        return (nx, ny, nz)
    }
    var out = Data()
    out.append(Data(count: 80)) // header (unused)
    var count = UInt32(faces.count)
    withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
    for (a, b, c) in faces {
        let n = normal(a, b, c)
        for p in [n, a, b, c] {
            for component in [p.0, p.1, p.2] {
                var f = component
                withUnsafeBytes(of: &f) { out.append(contentsOf: $0) }
            }
        }
        out.append(contentsOf: [UInt8(0), UInt8(0)]) // attribute byte count
    }
    return out
}

/// Ensures `root` (the app's Documents folder) exists and contains at
/// least one STL; writes the example cube when it contains none.
/// Returns true when the example file was written. Never overwrites:
/// when any `.stl` is already present — including in the Inbox
/// subfolder — nothing is written.
@discardableResult
func seedExampleSTLIfNeeded(in root: URL, fileManager: FileManager = .default) -> Bool {
    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    guard listLocalSTLFiles(in: root, fileManager: fileManager).isEmpty else { return false }
    do {
        try exampleCubeSTLData().write(to: root.appendingPathComponent(exampleSTLFileName),
                                       options: .atomic)
        return true
    } catch {
        return false
    }
}
