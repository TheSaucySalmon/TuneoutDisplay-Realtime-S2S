#version 460 core
#include <flutter/runtime_effect.glsl>
precision highp float;

// Card is drawn in its own local space; uCardOffset maps it back onto the
// full-screen background texture so refraction samples the *real* background.
layout(location = 0) uniform vec2 uScreen;      // logical screen size
layout(location = 1) uniform vec2 uCardOffset;  // card top-left, global logical px
layout(location = 2) uniform vec2 uCardSize;    // card size, logical px
layout(location = 3) uniform float uRadius;     // corner radius
layout(location = 4) uniform float uThickness;  // refraction strength (px)
layout(location = 5) uniform float uLightAngle; // specular light direction
uniform sampler2D uTex;                          // low-res snapshot of the bg

out vec4 fragColor;

float sdRoundedBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// Sample the background texture at a global pixel coordinate.
vec3 bg(vec2 globalPx) {
  return texture(uTex, clamp(globalPx / uScreen, 0.0, 1.0)).rgb;
}

void main() {
  vec2 fc = FlutterFragCoord().xy;
  vec2 b = uCardSize * 0.5;
  vec2 p = fc - b;
  float d = sdRoundedBox(p, b, uRadius);

  if (d > 1.0) { fragColor = vec4(0.0); return; }

  // SDF surface normal.
  float e = 1.0;
  vec2 n = normalize(vec2(
    sdRoundedBox(p + vec2(e, 0.0), b, uRadius) - sdRoundedBox(p - vec2(e, 0.0), b, uRadius),
    sdRoundedBox(p + vec2(0.0, e), b, uRadius) - sdRoundedBox(p - vec2(0.0, e), b, uRadius)));

  // Lens profile: flat centre, curving hard at the rim — clear middle, strong
  // edge warp.
  float edge = smoothstep(-uThickness, 0.0, d);
  float bend = pow(edge, 2.2) * uThickness;

  // Refraction with a subtle chromatic split — now three cheap texture reads.
  vec2 base = uCardOffset + fc + n * bend;
  vec3 col;
  col.r = bg(base + n * 1.5).r;
  col.g = bg(base).g;
  col.b = bg(base - n * 1.5).b;

  // Faint, mostly-transparent tint.
  col = mix(col, vec3(0.60, 0.69, 0.86), 0.08);

  // Thin specular rim along the curved edge.
  vec2 lightDir = vec2(cos(uLightAngle), sin(uLightAngle));
  float sheen = pow(max(dot(n, lightDir), 0.0), 1.5);
  float rim = smoothstep(-2.5, 0.0, d);
  col += rim * (0.16 + 0.55 * sheen);

  // Soft shade on the far edge for thickness.
  float shade = rim * max(dot(n, -lightDir), 0.0);
  col -= shade * 0.10;

  float aa = 1.0 - smoothstep(-1.0, 1.0, d);
  fragColor = vec4(col, aa);
}
