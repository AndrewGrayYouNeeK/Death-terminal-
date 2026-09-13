#version 450

layout(location = 0) in vec2 inCorner;
layout(location = 1) in vec2 inOrigin;
layout(location = 2) in vec2 inSize;
layout(location = 3) in vec2 inUvOrigin;
layout(location = 4) in vec2 inUvSize;
layout(location = 5) in vec4 inFg;
layout(location = 6) in vec4 inBg;

layout(location = 0) out vec2 vUv;
layout(location = 1) out vec4 vFg;
layout(location = 2) out vec4 vBg;

void main() {
    vec2 pos = inOrigin + inCorner * inSize;
    gl_Position = vec4(pos, 0.0, 1.0);
    vUv = inUvOrigin + inCorner * inUvSize;
    vFg = inFg;
    vBg = inBg;
}
