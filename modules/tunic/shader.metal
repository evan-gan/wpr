// after the TUNIC title screen: cyan filaments streaming diagonally over navy, a crimson bloom in
// one upper corner, and a field of colored sparkle motes.
//
// the look is a single intensity field pushed through a measured ramp (sRGB, from the reference):
//   0.00 -> (2,26,39) navy    0.30 -> (5,62,98) blue    0.65 -> (44,157,208) cyan    1.00 -> (120,210,230)

float3 srgb(float r, float g, float b) { return pow(float3(r, g, b) / 255.0, float3(2.2)); }

float3 ramp(float t) {
  float3 c0 = srgb(2, 26, 39), c1 = srgb(5, 62, 98), c2 = srgb(44, 157, 208), c3 = srgb(120, 210, 230);
  t = clamp(t, 0.0, 1.0);
  if (t < 0.30) return mix(c0, c1, t / 0.30);
  if (t < 0.65) return mix(c1, c2, (t - 0.30) / 0.35);
  return mix(c2, c3, (t - 0.65) / 0.35);
}

// how the game does it (one quad, shader "spiritfog"): the same blurry cloud texture sampled through
// two UV sets stretched along the flow, intersected with min() and pushed through a steep curve.
// the intersection of two independent clouds is what breaks smooth bands into filaments.
// returns (haze, filament, core)
float3 wisps(float2 p, float2 dir, float so) {
  float2 perp = float2(-dir.y, dir.x);
  float along = dot(p, dir), across = dot(p, perp);
  float bend = (fbm(float2(along * 0.5, across * 1.0) + so, 3) - 0.5) * 0.3;
  float2 q = float2(across + bend, along) + so * 2.3;
  // the second layer sits a few degrees off the first, like the game's two scroll directions,
  // so the intersections aren't one parallel whoosh
  float rot = 0.07;
  float2 q2 = float2(q.x * cos(rot) - q.y * sin(rot), q.x * sin(rot) + q.y * cos(rot));
  float a = fbm(q * float2(5.5, 1.1), 4);
  float b = fbm(q2 * float2(9.5, 1.9) + 17.0, 4);
  float m = min(a, b);
  float haze = smoothstep(0.44, 0.78, a);
  float filament = pow(smoothstep(0.46, 0.70, m), 1.4);
  float core = pow(smoothstep(0.58, 0.76, m), 1.3);
  return float3(haze, filament, core);
}

// the game's particles pick a start color along a red -> green -> blue -> white gradient and render
// additively at high intensity, so cores bloom toward white
float3 moteColor(float h) {
  float3 c;
  if (h < 0.25) c = float3(1.0, 0.02, 0.02);
  else if (h < 0.50) c = float3(0.09, 0.59, 0.13);
  else if (h < 0.75) c = float3(0.0, 0.46, 1.0);
  else c = float3(1.0, 1.0, 1.0);
  return mix(c, float3(1.0), 0.35);
}

// jittered-grid point field; softness > 1 turns pinpoints into bokeh discs
float3 motes(float2 p, float scale, float so, float softness, float density, float sizeMul) {
  float2 g = p * scale + so;
  float2 cell = floor(g), f = fract(g);
  float3 acc = 0.0;
  for (int y = -1; y <= 1; y++) {
    for (int x = -1; x <= 1; x++) {
      float2 c = cell + float2(x, y);
      float pick = hash21(c + so * 1.7);
      if (pick > density) continue;
      float2 pos = float2(hash21(c + 1.3), hash21(c + 2.7));
      float dist = length(f - float2(x, y) - pos);
      float size = mix(0.045, 0.075, hash21(c + 5.1)) * sizeMul;
      float glow = exp(-dist * dist / (size * size * softness));
      float bright = mix(0.35, 1.0, hash21(c + 9.9));
      acc += moteColor(hash21(c + 13.3)) * glow * bright;
    }
  }
  return acc;
}

float4 wp_main(float2 uv, constant Uniforms& u) {
  float aspect = u.res.x / u.res.y;
  float2 p = (uv - 0.5) * float2(aspect, 1.0);
  float so = hash11(u.seed) * 100.0;

  // flow runs lower-left to upper-right at ~30-45 degrees; the red corner sits at the top on one side
  float angle = mix(28.0, 46.0, hash11(u.seed + 1.0)) * M_PI_F / 180.0;
  float2 dir = float2(cos(angle), sin(angle));
  float side = hash11(u.seed + 2.0) < 0.5 ? 1.0 : -1.0;
  float2 pf = float2(p.x * side, p.y);
  float2 uvf = float2(side > 0.0 ? uv.x : 1.0 - uv.x, uv.y);

  // intensity: a glow in the lower corner the flow rises from, plus the streak layers, easing off
  // along the flow diagonal but never gone: the wisps reach into the green side and under the red
  float3 w = wisps(pf, dir, so);
  float t = 0.62 * uvf.y + 0.38 * uvf.x;
  float falloff = pow(smoothstep(1.0, 0.0, t), 1.4);
  // corner glow measured in aspect-corrected units so it's the same physical size on any display
  float2 corner = float2(-aspect * 0.5 + 0.08, -0.5);
  float glow = exp(-length((pf - corner) * float2(1.0, 1.9)) * 2.8);
  float ambient = 0.10 + 0.10 * falloff;
  float streaks = (0.35 * w.x + 0.75 * w.y + 0.50 * w.z) * (0.30 + 0.70 * falloff);
  float bottom = 0.18 * exp(-uvf.y * 3.5) * (0.4 + 0.6 * w.x);
  float energy = ambient + 0.6 * glow + streaks + bottom;
  // soft shoulder: highlights gradate toward the ramp's top instead of clipping into a slab
  float intensity = 1.0 - exp(-energy * 1.25);
  float3 col = ramp(intensity);

  // the far side runs greener than the near side
  float3 green = srgb(9, 97, 98);
  col = mix(col, green * (0.3 + intensity * 1.6), smoothstep(0.25, 0.9, uvf.x) * 0.6);

  // motes: pinpoints plus a slightly larger, softer layer — a narrow range, like the game's
  float density = mix(0.16, 0.26, hash11(u.seed + 3.0));
  col += motes(p, 22.0, so + 3.0, 1.1, density, 0.8) * 0.85;
  col += motes(p, 10.0, so + 7.0, 1.6, density * 0.4, 1.0) * 0.45;

  // the crimson corner is a post-process overlay in the game: it goes on after the wisps AND the
  // motes, tinting whatever is under it. gaussian: wide lobe, bounded tail. measured (116,37,46)
  float2 rd = (uvf - float2(1.0, 1.02)) * float2(1.3, 1.6);
  float red = exp(-dot(rd, rd) * 2.5);
  col = mix(col, srgb(116, 37, 46) * (1.0 + 0.3 * red), min(1.0, red * 1.05) * 0.8);

  col *= 1.0 - 0.2 * dot(uv - 0.5, uv - 0.5);
  col = pow(max(col, 0.0), float3(1.0 / 2.2));
  col += (hash21(uv * u.res + u.seed) - 0.5) * 0.006;
  return float4(min(col, 1.0), 1.0);
}
