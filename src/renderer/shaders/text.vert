#version 450

// Per-vertex unit quad corner.
layout(location = 0) in vec2 inCorner;
// Per-instance, in framebuffer pixels / atlas texels.
layout(location = 1) in vec2 inOrigin;
layout(location = 2) in vec2 inSize;
layout(location = 3) in uvec2 inUvOrigin;
layout(location = 4) in uvec2 inUvSize;
layout(location = 5) in vec4 inColor;
layout(location = 6) in uint inKind;

layout(push_constant) uniform Push {
    vec2 invViewport;
    vec2 invAtlas;
    uint srgb;
} pc;

layout(location = 0) out vec2 vUv;
layout(location = 1) out vec4 vColor;
layout(location = 2) flat out uint vKind;

vec3 toLinear(vec3 c) {
    vec3 lo = c / 12.92;
    vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
    return mix(hi, lo, lessThanEqual(c, vec3(0.04045)));
}

void main() {
    vec2 px = inOrigin + inCorner * inSize;
    gl_Position = vec4(px * pc.invViewport * 2.0 - 1.0, 0.0, 1.0);
    vUv = (vec2(inUvOrigin) + inCorner * vec2(inUvSize)) * pc.invAtlas;
    vColor = vec4(pc.srgb != 0u ? toLinear(inColor.rgb) : inColor.rgb, 1.0);
    vKind = inKind;
}
