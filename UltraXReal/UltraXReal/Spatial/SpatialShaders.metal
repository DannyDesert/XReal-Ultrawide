#include <metal_stdlib>
using namespace metal;

// Layout must match FloatingUniforms in SpatialRenderer.swift.
struct FloatingUniforms {
    float3x3 headMatrix;     // view-space head rotation (camera ray → world dir)
    float2 tanHalfFov;       // glasses half-FOV tangents (x, y)
    float2 screenHalfSize;   // floating screen half extents, meters
    float distance;          // screen distance in meters (lean-zoom applied)
    float _pad0;
    float2 _pad1;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen quad — triangle strip, 4 vertices, no vertex buffer needed
vertex VertexOut spatialVertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)
    };
    float2 texCoords[4] = {
        float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0, 1);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Raycast a world-locked screen quad: for each output pixel, build the camera
// ray, rotate it by the head orientation, and intersect the fixed screen plane
// at z = -distance in the recentered world frame. Black (= transparent on the
// glasses' additive OLEDs) everywhere the ray misses the screen.
fragment float4 spatialFragment(
    VertexOut in [[stage_in]],
    texture2d<float> screenTexture [[texture(0)]],
    constant FloatingUniforms &u [[buffer(0)]]
) {
    float2 ndc = float2(in.texCoord.x * 2.0 - 1.0, 1.0 - in.texCoord.y * 2.0);
    float3 ray = normalize(float3(ndc.x * u.tanHalfFov.x, ndc.y * u.tanHalfFov.y, -1.0));
    float3 dir = u.headMatrix * ray;

    // Screen is on the plane z = -distance; rays pointing away never hit it.
    if (dir.z >= -1e-4) {
        return float4(0, 0, 0, 1);
    }

    float t = -u.distance / dir.z;
    float2 hit = t * dir.xy;

    float2 uv = float2(
        hit.x / (2.0 * u.screenHalfSize.x) + 0.5,
        0.5 - hit.y / (2.0 * u.screenHalfSize.y)
    );

    if (any(uv < 0.0) || any(uv > 1.0)) {
        return float4(0, 0, 0, 1);
    }

    constexpr sampler s(filter::linear, mip_filter::linear,
                        max_anisotropy(8), address::clamp_to_edge);
    return screenTexture.sample(s, uv);
}
