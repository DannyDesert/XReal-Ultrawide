#include <metal_stdlib>
using namespace metal;

struct ViewportUniforms {
    float2 viewportOrigin;  // Top-left of crop rect, normalized [0,1]
    float2 viewportSize;    // Size of crop rect, normalized [0,1]
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

// Samples a viewport sub-region of the canvas texture
fragment float4 spatialFragment(
    VertexOut in [[stage_in]],
    texture2d<float> canvasTexture [[texture(0)]],
    constant ViewportUniforms &uniforms [[buffer(0)]]
) {
    // Map output texcoord [0,1] to the viewport region on the canvas
    float2 sampleCoord = uniforms.viewportOrigin + in.texCoord * uniforms.viewportSize;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return canvasTexture.sample(s, sampleCoord);
}
