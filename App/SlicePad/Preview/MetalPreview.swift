import SwiftUI
import Metal
import MetalKit
import simd

// MARK: - MetalPreview
//
// UIViewRepresentable wrapping an MTKView that renders:
//  (a) the imported mesh — flat-shaded triangles (per-face normals computed
//      on the CPU, Lambert shading in Shaders.metal), centred on the bed;
//  (b) toolpath preview lines from SliceResult.preview, filtered by the
//      layer slider (only paths at z <= layerZ are drawn);
//  (c) a 180x180 mm bed grid with plate bounds.
// Camera: one-finger drag orbits (azimuth / polar angle), pinch zooms,
// two-finger drag pans. Everything is guarded so a nil Metal device
// degrades to an empty view instead of a crash.

enum PreviewDisplayMode {
    case mesh
    case toolpath
    case both
}

struct MetalPreview: UIViewRepresentable {
    var mesh: Mesh?
    var previewPaths: [PreviewPath]
    var displayMode: PreviewDisplayMode
    var layerZ: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        context.coordinator.renderer.attach(to: view)
        view.delegate = context.coordinator.renderer
        context.coordinator.installGestures(on: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer.update(mesh: mesh,
                                            previewPaths: previewPaths,
                                            displayMode: displayMode,
                                            layerZ: layerZ)
        view.setNeedsDisplay()
    }

    // MARK: Coordinator — gestures

    final class Coordinator: NSObject {
        let renderer = Renderer()
        private weak var view: MTKView?
        private var panStartAzimuth: Float = 0
        private var panStartPolar: Float = 0
        private var pinchStartDistance: Float = 0
        private var pan2StartTarget = SIMD3<Float>(repeating: 0)

        func installGestures(on view: MTKView) {
            self.view = view
            let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
            orbit.minimumNumberOfTouches = 1
            orbit.maximumNumberOfTouches = 1
            view.addGestureRecognizer(orbit)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            view.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            view.addGestureRecognizer(pinch)
        }

        @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            switch gesture.state {
            case .began:
                panStartAzimuth = renderer.azimuth
                panStartPolar = renderer.polar
            case .changed:
                let t = gesture.translation(in: view)
                renderer.azimuth = panStartAzimuth + Float(t.x) * 0.01
                renderer.polar = min(1.62, max(0.05, panStartPolar - Float(t.y) * 0.008))
                view.setNeedsDisplay()
            default:
                break
            }
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            switch gesture.state {
            case .began:
                pan2StartTarget = renderer.target
            case .changed:
                let t = gesture.translation(in: view)
                let scale = renderer.distance * 0.0016
                let (right, up) = renderer.cameraRightAndUp()
                renderer.target = pan2StartTarget
                    - right * Float(t.x) * scale
                    + up * Float(t.y) * scale
                view.setNeedsDisplay()
            default:
                break
            }
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view else { return }
            switch gesture.state {
            case .began:
                pinchStartDistance = renderer.distance
            case .changed:
                let factor = Float(gesture.scale)
                if factor > 0.01 {
                    renderer.distance = min(1200, max(30, pinchStartDistance / factor))
                    view.setNeedsDisplay()
                }
            default:
                break
            }
        }
    }
}

// MARK: - Renderer

private struct Uniforms {
    var mvp: simd_float4x4
    var modelView: simd_float4x4
    var color: SIMD4<Float>
}

private struct TriangleVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
}

private struct LineVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
}

final class Renderer: NSObject, MTKViewDelegate {
    // Camera (spherical, Z-up world, target starts at bed centre).
    var azimuth: Float = 0.7        // radians around Z
    var polar: Float = 0.95         // radians from +Z axis
    var distance: Float = 300       // mm
    var target = SIMD3<Float>(90, 90, 12)

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var trianglePipeline: MTLRenderPipelineState?
    private var linePipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?

    private var meshBuffer: MTLBuffer?
    private var meshVertexCount = 0
    private var gridBuffer: MTLBuffer?
    private var gridVertexCount = 0
    private var toolpathBuffer: MTLBuffer?
    private var toolpathVertexCount = 0

    private var showMesh = true
    private var showToolpath = false
    private var meshSignature = ""
    private var toolpathSignature = ""

    func attach(to view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else { return }
        self.device = device
        commandQueue = device.makeCommandQueue()
        guard let library = device.makeDefaultLibrary() else { return }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDescriptor)

        // Triangle pipeline
        if let vertexFn = library.makeFunction(name: "triangleVertex"),
           let fragmentFn = library.makeFunction(name: "triangleFragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFn
            descriptor.fragmentFunction = fragmentFn
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            let vd = MTLVertexDescriptor()
            vd.attributes[0].format = .float3
            vd.attributes[0].offset = 0
            vd.attributes[0].bufferIndex = 0
            vd.attributes[1].format = .float3
            vd.attributes[1].offset = 16
            vd.attributes[1].bufferIndex = 0
            vd.layouts[0].stride = MemoryLayout<TriangleVertex>.stride
            descriptor.vertexDescriptor = vd
            trianglePipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        // Line pipeline
        if let vertexFn = library.makeFunction(name: "lineVertex"),
           let fragmentFn = library.makeFunction(name: "lineFragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFn
            descriptor.fragmentFunction = fragmentFn
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            let vd = MTLVertexDescriptor()
            vd.attributes[0].format = .float3
            vd.attributes[0].offset = 0
            vd.attributes[0].bufferIndex = 0
            vd.attributes[1].format = .float4
            vd.attributes[1].offset = 16
            vd.attributes[1].bufferIndex = 0
            vd.layouts[0].stride = MemoryLayout<LineVertex>.stride
            descriptor.vertexDescriptor = vd
            linePipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        buildGrid()
    }

    // MARK: Content updates (rebuild buffers only when inputs change)

    func update(mesh: Mesh?, previewPaths: [PreviewPath],
                displayMode: PreviewDisplayMode, layerZ: Double) {
        showMesh = displayMode != .toolpath
        showToolpath = displayMode != .mesh

        let newMeshSignature = mesh.map { "\($0.name)|\($0.triangles.count)" } ?? "none"
        if newMeshSignature != meshSignature {
            meshSignature = newMeshSignature
            buildMesh(mesh)
        }
        let quantizedZ = (layerZ * 2).rounded() / 2
        let pathCount = previewPaths.reduce(0) { $0 + $1.points.count }
        let newPathSignature = "\(previewPaths.count)|\(pathCount)|\(quantizedZ)"
        if newPathSignature != toolpathSignature {
            toolpathSignature = newPathSignature
            buildToolpaths(previewPaths, layerZ: Float(layerZ))
        }
    }

    private func buildMesh(_ mesh: Mesh?) {
        meshBuffer = nil
        meshVertexCount = 0
        guard let mesh, let device, !mesh.triangles.isEmpty else { return }

        // Centre the model on the 180x180 bed, resting on z = 0.
        let minX = Float(mesh.minB.x), minY = Float(mesh.minB.y), minZ = Float(mesh.minB.z)
        let maxX = Float(mesh.maxB.x), maxY = Float(mesh.maxB.y)
        let offset = SIMD3<Float>(90 - (minX + maxX) / 2, 90 - (minY + maxY) / 2, -minZ)

        var vertices: [TriangleVertex] = []
        vertices.reserveCapacity(mesh.triangles.count * 3)
        var pending: [SIMD3<Float>] = [] // for flat [Vec3] triangle storage
        for triangle in mesh.triangles {
            let leaves = Renderer.numericLeaves(of: triangle)
            if leaves.count >= 9 {
                // 3 vertices (+ optionally a stored normal, taken as the
                // trailing triple when present) — first 9 values are the
                // vertex coordinates in declaration order.
                let a = SIMD3<Float>(leaves[0], leaves[1], leaves[2])
                let b = SIMD3<Float>(leaves[3], leaves[4], leaves[5])
                let c = SIMD3<Float>(leaves[6], leaves[7], leaves[8])
                Renderer.appendTriangle(a, b, c, offset: offset, into: &vertices)
            } else if leaves.count == 3 {
                pending.append(SIMD3<Float>(leaves[0], leaves[1], leaves[2]))
                if pending.count == 3 {
                    Renderer.appendTriangle(pending[0], pending[1], pending[2],
                                            offset: offset, into: &vertices)
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
        guard !vertices.isEmpty else { return }
        meshVertexCount = vertices.count
        meshBuffer = device.makeBuffer(bytes: vertices,
                                       length: vertices.count * MemoryLayout<TriangleVertex>.stride,
                                       options: [.storageModeShared])
    }

    private static func appendTriangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                                       offset: SIMD3<Float>, into vertices: inout [TriangleVertex]) {
        let n = simd_normalize(simd_cross(b - a, c - a))
        let normal = (n.x.isNaN || n.y.isNaN || n.z.isNaN) ? SIMD3<Float>(0, 0, 1) : n
        for v in [a, b, c] {
            let p = v + offset
            vertices.append(TriangleVertex(position: SIMD4<Float>(p, 1),
                                           normal: SIMD4<Float>(normal, 0)))
        }
    }

    private func buildToolpaths(_ paths: [PreviewPath], layerZ: Float) {
        toolpathBuffer = nil
        toolpathVertexCount = 0
        guard let device, !paths.isEmpty else { return }

        var vertices: [LineVertex] = []
        for path in paths {
            let kind = String(describing: path.kind).lowercased()
            if kind.contains("travel") { continue } // travel moves: clutter, skip
            let color = Renderer.color(forKind: kind)
            let points = path.points
            guard points.count >= 2 else { continue }
            for i in 0..<(points.count - 1) {
                let p0 = points[i], p1 = points[i + 1]
                // Show paths with z <= slider value.
                guard Float(p0.z) <= layerZ + 0.001, Float(p1.z) <= layerZ + 0.001 else { continue }
                vertices.append(LineVertex(position: SIMD4<Float>(Float(p0.x), Float(p0.y), Float(p0.z), 1), color: color))
                vertices.append(LineVertex(position: SIMD4<Float>(Float(p1.x), Float(p1.y), Float(p1.z), 1), color: color))
            }
        }
        guard !vertices.isEmpty else { return }
        toolpathVertexCount = vertices.count
        toolpathBuffer = device.makeBuffer(bytes: vertices,
                                           length: vertices.count * MemoryLayout<LineVertex>.stride,
                                           options: [.storageModeShared])
    }

    private static func color(forKind kind: String) -> SIMD4<Float> {
        if kind.contains("outer") || kind.contains("perimeter") && kind.contains("outer") {
            return SIMD4<Float>(0.25, 0.95, 0.35, 1)
        }
        if kind.contains("perimeter") || kind.contains("wall") {
            return SIMD4<Float>(0.2, 0.8, 0.55, 1)
        }
        if kind.contains("top") {
            return SIMD4<Float>(0.98, 0.85, 0.25, 1)
        }
        if kind.contains("solid") {
            return SIMD4<Float>(0.98, 0.6, 0.2, 1)
        }
        if kind.contains("infill") {
            return SIMD4<Float>(0.95, 0.45, 0.15, 0.9)
        }
        if kind.contains("support") {
            return SIMD4<Float>(0.45, 0.55, 0.95, 0.9)
        }
        if kind.contains("skirt") {
            return SIMD4<Float>(0.75, 0.4, 0.95, 1)
        }
        if kind.contains("brim") {
            return SIMD4<Float>(0.9, 0.35, 0.75, 1)
        }
        return SIMD4<Float>(0.55, 0.9, 0.6, 0.95)
    }

    private func buildGrid() {
        guard let device else { return }
        var vertices: [LineVertex] = []
        let faint = SIMD4<Float>(0.32, 0.34, 0.4, 1)
        let border = SIMD4<Float>(0.75, 0.78, 0.85, 1)
        func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ color: SIMD4<Float>) {
            vertices.append(LineVertex(position: SIMD4<Float>(a, 1), color: color))
            vertices.append(LineVertex(position: SIMD4<Float>(b, 1), color: color))
        }
        // Grid every 10 mm over the 180x180 plate.
        for i in stride(from: 0, through: 180, by: 10) {
            let f = Float(i)
            line(SIMD3(f, 0, 0), SIMD3(f, 180, 0), faint)
            line(SIMD3(0, f, 0), SIMD3(180, f, 0), faint)
        }
        // Plate bounds.
        line(SIMD3(0, 0, 0), SIMD3(180, 0, 0), border)
        line(SIMD3(180, 0, 0), SIMD3(180, 180, 0), border)
        line(SIMD3(180, 180, 0), SIMD3(0, 180, 0), border)
        line(SIMD3(0, 180, 0), SIMD3(0, 0, 0), border)
        gridVertexCount = vertices.count
        gridBuffer = device.makeBuffer(bytes: vertices,
                                       length: vertices.count * MemoryLayout<LineVertex>.stride,
                                       options: [.storageModeShared])
    }

    // MARK: Camera math

    func cameraRightAndUp() -> (SIMD3<Float>, SIMD3<Float>) {
        let eye = cameraEye()
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 0, 1)))
        let up = simd_cross(right, forward)
        return (right, up)
    }

    private func cameraEye() -> SIMD3<Float> {
        let offset = SIMD3<Float>(distance * sin(polar) * cos(azimuth),
                                  distance * sin(polar) * sin(azimuth),
                                  distance * cos(polar))
        return target + offset
    }

    private func viewMatrix() -> simd_float4x4 {
        let eye = cameraEye()
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 0, 1)))
        let up = simd_cross(right, forward)
        return simd_float4x4(columns: (
            SIMD4<Float>(right.x, up.x, -forward.x, 0),
            SIMD4<Float>(right.y, up.y, -forward.y, 0),
            SIMD4<Float>(right.z, up.z, -forward.z, 0),
            SIMD4<Float>(-simd_dot(right, eye), -simd_dot(up, eye), simd_dot(forward, eye), 1)
        ))
    }

    private func projectionMatrix(aspect: Float) -> simd_float4x4 {
        let fov: Float = 45 * .pi / 180
        let f = 1 / tan(fov / 2)
        let near: Float = 1
        let far: Float = 3000
        let a = far / (near - far)
        let b = near * far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(f / aspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, a, -1),
            SIMD4<Float>(0, 0, b, 0)
        ))
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let device, let commandQueue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        _ = device

        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        let viewM = viewMatrix()
        var uniforms = Uniforms(mvp: projectionMatrix(aspect: aspect) * viewM,
                                modelView: viewM,
                                color: SIMD4<Float>(0.45, 0.75, 0.95, 1))

        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)

        // Bed grid
        if let linePipeline, let gridBuffer {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridVertexCount)
        }

        // Mesh triangles
        if showMesh, let trianglePipeline, let meshBuffer {
            encoder.setRenderPipelineState(trianglePipeline)
            encoder.setVertexBuffer(meshBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: meshVertexCount)
        }

        // Toolpath lines
        if showToolpath, let linePipeline, let toolpathBuffer {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(toolpathBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: toolpathVertexCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Triangle vertex extraction
    //
    // The Core Triangle type's exact stored shape (a/b/c, v0/v1/v2, flat
    // vertex list, optional stored normal) is not part of the published
    // API surface, so vertices are extracted structurally: walk the value
    // with Mirror and collect numeric leaves in declaration order. A
    // triangle yields 9 values (3 vertices), or 3 when Mesh.triangles is
    // a flat vertex list (handled by accumulation in buildMesh).

    static func numericLeaves(of value: Any) -> [Float] {
        var out: [Float] = []
        func walk(_ v: Any) {
            switch v {
            case let f as Float:
                out.append(f)
            case let d as Double:
                out.append(Float(d))
            case let i as Int:
                out.append(Float(i))
            case let i as Int32:
                out.append(Float(i))
            default:
                let mirror = Mirror(reflecting: v)
                for child in mirror.children {
                    walk(child.value)
                }
            }
        }
        walk(value)
        return out
    }
}
