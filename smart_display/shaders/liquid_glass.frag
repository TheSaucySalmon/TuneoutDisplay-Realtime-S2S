#version 460 core
#include <flutter/runtime_effect.glsl>
precision highp float;

// Card is drawn in its own local space; uCardOffset maps it back onto the
// full-screen glow field so refraction samples the *real* background.
layout(location = 0) uniform vec2 uScreen;     // logical screen size
layout(location = 1) uniform vec2 uCardOffset;  // card top-left, global logical px
layout(location = 2) uniform vec2 uCardSize;    // card size, logical px
layout(location = 3) uniform float uRadius;     // corner radius
layout(location = 4) uniform float uTime;       // 0..1, shared with background
layout(location = 5) uniform float uThickness;  // refraction strength (px)
layout(location = 6) uniform float uLightAngle; // specular light direction

out vec4 fragColor;

const float TAU = 6.28318530718;

float sdRoundedBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// Mirror of the Dart _GlowPainter so the glass shows the true background.
vec3 glow(vec2 gp) {
  float ss = min(uScreen.x, uScreen.y);
  vec3 col = vec3(0.0235, 0.0314, 0.0588);
  vec2 c1 = vec2(0.25 + 0.10 * sin(uTime * TAU),
                 0.30 + 0.06 * cos(uTime * TAU)) * uScreen;
  col = mix(col, vec3(46.0, 107.0, 255.0) / 255.0,
            0.40 * (1.0 - clamp(distance(gp, c1) / (ss * 0.70), 0.0, 1.0)));
  vec2 c2 = vec2(0.80 + 0.08 * cos(uTime * TAU),
                 0.70 + 0.07 * sin(uTime * TAU)) * uScreen;
  col = mix(col, vec3(255.0, 138.0, 61.0) / 255.0,
            0.30 * (1.0 - clamp(distance(gp, c2) / (ss * 0.60), 0.0, 1.0)));
  vec2 c3 = vec2(0.55 + 0.06 * sin(uTime * TAU + 1.5),
                 0.85 + 0.05 * cos(uTime * TAU + 1.5)) * uScreen;
  col = mix(col, vec3(34.0, 211.0, 168.0) / 255.0,
            0.20 * (1.0 - clamp(distance(gp, c3) / (ss * 0.50), 0.0, 1.0)));
  return col;
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

  // Lens profile: flat in the centre, curving hard at the rim. The gradient of
  // that height is what bends the background — clear middle, strong edge warp.
  float edge = smoothstep(-uThickness, 0.0, d);
  float bend = pow(edge, 2.2) * uThickness;

  // Refraction with a subtle chromatic split (real glass disperses light).
  vec2 base = uCardOffset + fc + n * bend;
  vec3 col;
  col.r = glow(base + n * 1.5).r;
  col.g = glow(base).g;
  col.b = glow(base - n * 1.5).b;

  // Faint, mostly-transparent tint — keep it glassy, not milky.
  col = mix(col, vec3(0.60, 0.69, 0.86), 0.08);

  // Thin specular rim that catches the light along the curved edge.
  vec2 lightDir = vec2(cos(uLightAngle), sin(uLightAngle));
  float sheen = pow(max(dot(n, lightDir), 0.0), 1.5);
  float rim = smoothstep(-2.5, 0.0, d);
  col += rim * (0.16 + 0.55 * sheen);

  // Opposite edge picks up a soft shade to read as thickness.
  float shade = rim * max(dot(n, -lightDir), 0.0);
  col -= shade * 0.10;

  // Feather the outer boundary for clean anti-aliased corners.
  float aa = 1.0 - smoothstep(-1.0, 1.0, d);
  fragColor = vec4(col, aa);
}
