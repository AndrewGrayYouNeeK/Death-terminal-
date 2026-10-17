#version 450

layout(location = 0) in vec2 vUv;
layout(location = 1) in vec4 vColor;
layout(location = 2) flat in uint vKind;

layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform sampler2D uAtlas;

// Output is premultiplied; blending is ONE, ONE_MINUS_SRC_ALPHA.
void main() {
    if (vKind == 0u) {
        outColor = vec4(vColor.rgb, 1.0);
    } else if (vKind == 1u) {
        float a = texture(uAtlas, vUv).a;
        outColor = vec4(vColor.rgb * a, a);
    } else {
        outColor = texture(uAtlas, vUv);
    }
}
