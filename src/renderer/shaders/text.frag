#version 450

layout(location = 0) in vec2 vUv;
layout(location = 1) in vec4 vFg;
layout(location = 2) in vec4 vBg;

layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform sampler2D uAtlas;

void main() {
    float a = texture(uAtlas, vUv).r;
    outColor = mix(vBg, vFg, a);
}
