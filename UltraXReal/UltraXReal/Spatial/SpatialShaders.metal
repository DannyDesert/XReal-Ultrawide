#include <metal_stdlib>
using namespace metal;

// Matches Swift FloatingUniforms: matrix columns occupy 16 bytes each; stride 96.
struct FloatingUniforms {
    float3x3 headMatrix;
    float4 optics;         // half-FOV tangents, screen half-width/height
    float4 layout;         // distance, inward angle, gap, unused
    uint4 configuration;   // monitor count, valid-texture bitmask, unused
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

// Cast the actual glasses camera rays into stationary, inward-folded monitors.
fragment float4 spatialFragment(
    VertexOut in [[stage_in]],
    texture2d<float> firstTexture [[texture(0)]],
    texture2d<float> secondTexture [[texture(1)]],
    texture2d<float> thirdTexture [[texture(2)]],
    constant FloatingUniforms &u [[buffer(0)]]
) {
    float2 ndc = float2(in.texCoord.x * 2.0 - 1.0, 1.0 - in.texCoord.y * 2.0);
    float3 dir = u.headMatrix * normalize(float3(ndc * u.optics.xy, -1.0));
    float halfWidth = u.optics.z;
    float halfHeight = u.optics.w;
    float distance = u.layout.x;
    float angle = u.layout.y;
    float gap = u.layout.z;
    uint count = min(u.configuration.x, 3u);
    float nearest = INFINITY;
    float2 uv = float2(0);
    int selected = -1;
    for (uint panel = 0; panel < count; ++panel) {
        if ((u.configuration.y & (1u << panel)) == 0) { continue; }
        float side = count == 1 ? 0.0 : (count == 2 ? float(panel) * 2.0 - 1.0 : float(panel) - 1.0);
        float tilt = count == 2 ? angle * 0.5 : angle;
        float sine = side * sin(tilt);
        float cosine = side == 0.0 ? 1.0 : cos(tilt);
        float3 right = float3(cosine, 0.0, sine);
        float3 center;
        if (count == 2) {
            // Symmetric around the seam; both panels meet at z=-distance.
            center = float3(side * (halfWidth * cosine + gap * 0.5), 0.0,
                            -distance + halfWidth * sin(tilt));
        } else {
            center = float3(side * (halfWidth + gap + halfWidth * cosine), 0.0,
                            -distance + abs(side) * halfWidth * sin(tilt));
        }
        float3 normal = cross(right, float3(0, 1, 0));
        float denominator = dot(dir, normal);
        if (denominator >= -1e-6) { continue; }
        float t = dot(center, normal) / denominator;
        if (t <= 0 || t >= nearest) { continue; }
        float3 hit = t * dir - center;
        float2 local = float2(dot(hit, right), hit.y);
        if (abs(local.x) > halfWidth || abs(local.y) > halfHeight) { continue; }
        nearest = t;
        selected = int(panel);
        uv = float2(local.x / (2 * halfWidth) + 0.5, 0.5 - local.y / (2 * halfHeight));
    }
    constexpr sampler s(filter::linear, mip_filter::linear,
                        max_anisotropy(8), address::clamp_to_edge);
    switch (selected) {
        case 0: return firstTexture.sample(s, uv);
        case 1: return secondTexture.sample(s, uv);
        case 2: return thirdTexture.sample(s, uv);
        default: return float4(0, 0, 0, 1);
    }
}
