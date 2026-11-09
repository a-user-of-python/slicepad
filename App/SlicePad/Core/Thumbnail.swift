// Thumbnail.swift — SlicePad slicer core: plate thumbnail rendering.
// Top-view software rasteriser: triangles are projected onto XY and
// filled into an RGB pixel buffer (light model on a dark background),
// then encoded as a PNG written from scratch — zlib stream made of
// STORED blocks (no compression) with Adler-32, and CRC-32 chunk
// checksums. Foundation only.

import Foundation

private func appendBE32(_ d: inout Data, _ v: UInt32) {
    d.append(UInt8((v >> 24) & 0xFF)); d.append(UInt8((v >> 16) & 0xFF))
    d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF))
}

private func pngChunk(_ type: String, _ payload: Data) -> Data {
    var out = Data()
    appendBE32(&out, UInt32(payload.count))
    let typeBytes = Data(type.utf8)
    out.append(typeBytes)
    out.append(payload)
    var crcInput = Data()
    crcInput.append(typeBytes)
    crcInput.append(payload)
    appendBE32(&out, spCRC32(crcInput))
    return out
}

/// Render a top-view thumbnail of the mesh as PNG data.
/// `size` is the square edge length in pixels.
public func makeThumbnailPNG(mesh: Mesh, size: Int) -> Data {
    let n = max(size, 1)
    // Dark background (24,24,28), light model (215,215,215).
    var pixels = [UInt8](repeating: 0, count: n * n * 3)
    for i in 0..<(n * n) {
        pixels[i * 3] = 24; pixels[i * 3 + 1] = 24; pixels[i * 3 + 2] = 28
    }

    if !mesh.triangles.isEmpty {
        let lo = mesh.minB, hi = mesh.maxB
        let spanX = max(hi.x - lo.x, 1e-9)
        let spanY = max(hi.y - lo.y, 1e-9)
        let span = max(spanX, spanY)
        let margin = 0.06 // 6% margin around the model
        let scale = Double(n) * (1.0 - 2.0 * margin) / span
        // Model-space point -> pixel coordinates (y up -> row down).
        func toPixel(_ p: Vec3) -> (Double, Double) {
            let cx = (Double(n) - spanX * scale) / 2.0 + (p.x - lo.x) * scale
            let cy = (Double(n) - spanY * scale) / 2.0 + (hi.y - p.y) * scale
            return (cx, cy)
        }
        for tri in mesh.triangles {
            // Skip near-vertical triangles seen edge-on from the top?
            // No: their projection is a sliver and fills almost nothing;
            // projecting everything keeps silhouettes solid.
            let (x0, y0) = toPixel(tri.a)
            let (x1, y1) = toPixel(tri.b)
            let (x2, y2) = toPixel(tri.c)
            let minX = max(0, Int(floor(min(x0, min(x1, x2)))))
            let maxX = min(n - 1, Int(ceil(max(x0, max(x1, x2)))))
            let minY = max(0, Int(floor(min(y0, min(y1, y2)))))
            let maxY = min(n - 1, Int(ceil(max(y0, max(y1, y2)))))
            if maxX < minX || maxY < minY { continue }
            let denom = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
            if abs(denom) < 1e-12 { continue } // degenerate projection
            for py in minY...maxY {
                for px in minX...maxX {
                    let cx = Double(px) + 0.5, cy = Double(py) + 0.5
                    let w0 = ((y1 - y2) * (cx - x2) + (x2 - x1) * (cy - y2)) / denom
                    let w1 = ((y2 - y0) * (cx - x2) + (x0 - x2) * (cy - y2)) / denom
                    let w2 = 1.0 - w0 - w1
                    if w0 >= -1e-9 && w1 >= -1e-9 && w2 >= -1e-9 {
                        let idx = (py * n + px) * 3
                        pixels[idx] = 215; pixels[idx + 1] = 215; pixels[idx + 2] = 215
                    }
                }
            }
        }
    }

    // Raw image data: filter byte 0 at the start of every row.
    var raw = Data()
    raw.reserveCapacity((n * 3 + 1) * n)
    for row in 0..<n {
        raw.append(0)
        raw.append(contentsOf: pixels[(row * n * 3)..<((row + 1) * n * 3)])
    }

    // zlib stream: header 0x78 0x01, STORED blocks, Adler-32 (big-endian).
    var idat = Data()
    idat.append(contentsOf: [0x78, 0x01])
    var offset = 0
    let rawBytes = [UInt8](raw)
    while offset < rawBytes.count {
        let blockLen = min(65535, rawBytes.count - offset)
        let isFinal = offset + blockLen == rawBytes.count
        idat.append(isFinal ? 1 : 0)
        idat.append(UInt8(blockLen & 0xFF)); idat.append(UInt8((blockLen >> 8) & 0xFF))
        let nlen = ~UInt16(blockLen)
        idat.append(UInt8(nlen & 0xFF)); idat.append(UInt8((nlen >> 8) & 0xFF))
        idat.append(contentsOf: rawBytes[offset..<(offset + blockLen)])
        offset += blockLen
    }
    if rawBytes.isEmpty {
        idat.append(contentsOf: [1, 0, 0, 0xFF, 0xFF])
    }
    appendBE32(&idat, spAdler32(rawBytes))

    var ihdr = Data()
    appendBE32(&ihdr, UInt32(n))
    appendBE32(&ihdr, UInt32(n))
    ihdr.append(contentsOf: [8, 2, 0, 0, 0]) // 8-bit RGB, no interlace

    var png = Data()
    png.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.append(pngChunk("IHDR", ihdr))
    png.append(pngChunk("IDAT", idat))
    png.append(pngChunk("IEND", Data()))
    return png
}
