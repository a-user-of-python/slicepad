#include <metal_stdlib>
using namespace metal;

// Shared uniforms — layout must match the Swift `Uniforms` struct in
// MetalPreview.swift (two float4x4 + one float4).
struct Uniforms {
    float4x4 mvp;
    float4x4 modelView;
    float4 color;
};

// MARK: - Triangles (flat shading, simple Lambert)
//
// Face normals are computed per-triangle on the CPU, so every vertex of a
// face carries the same normal and lighting is flat. Lighting is
// double-sided (abs of the dot product) because STL winding is not
// guaranteed consistent.

struct TriangleIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

struct TriangleOut {
    float4 clipPosition [[position]];
    float3 viewNormal;
};

vertex TriangleOut triangleVertex(TriangleIn in [[stage_in]],
                                  constant Uniforms &uniforms [[buffer(1)]]) {
    TriangleOut out;
    out.clipPosition = uniforms.mvp * float4(in.position, 1.0);
    out.viewNormal = (uniforms.modelView * float4(in.normal, 0.0)).xyz;
    return out;
}

fragment float4 triangleFragment(TriangleOut in [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(1)]]) {
    float3 n = normalize(in.viewNormal);
    float3 lightDir = normalize(float3(0.35, 0.55, 0.76)); // view-space, up-right
    float diffuse = abs(dot(n, lightDir));
    float shade = 0.28 + 0.72 * diffuse;
    return float4(uniforms.color.rgb * shade, uniforms.color.a);
}

// MARK: - Lines (grid + toolpaths, colour per vertex)

struct LineIn {
    float3 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct LineOut {
    float4 clipPosition [[position]];
    float4 color;
};

vertex LineOut lineVertex(LineIn in [[stage_in]],
                          constant Uniforms &uniforms [[buffer(1)]]) {
    LineOut out;
    out.clipPosition = uniforms.mvp * float4(in.position, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 lineFragment(LineOut in [[stage_in]]) {
    return in.color;
}
