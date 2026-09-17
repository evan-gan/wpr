// after "Auroras" by nimitz (@stormoid), https://www.shadertoy.com/view/XtGGRt, via the purple
// recolour https://www.shadertoy.com/view/3XsfRr — CC BY-NC-SA 3.0, this file carries the same license
//
// the curtain is 50 slices of a rotated triangle-wave noise, marched upward from the camera and
// coloured per slice from a palette, so the lower edge is bright and the top thins out.
// sky: a dark navy gradient with a wine glow on one side, stars from an integer hash on the ray.
// below the horizon the same scene is mirrored and a second noise pass ripples the water.
// the seed picks a moment of the animation, the palette, the yaw, the star lattice and which
// side the sky glow sits on. `wp stream` advances from that moment.
//
// glsl `v * mat2` is a row vector times the matrix; every one of those is vxm() here, so the
// curtain leans and the ripples run the same way as the original. no gamma step, as on shadertoy.

// `--set hue=N`: 0 purple (the recolour), 1 nimitz's green/teal, 2 ember (green -> red),
// 3 gold -> green; negative = seeded, about half of seeds purple
#ifndef WP_PARAM_hue
#define WP_PARAM_hue -1.0
#endif
// `--set yaw=0..1`: camera yaw, 0.5 is the original view and the ends are ±0.5 rad; negative = seeded
#ifndef WP_PARAM_yaw
#define WP_PARAM_yaw -1.0
#endif

constant float2x2 m2 = float2x2(float2(0.95534, 0.29552), float2(-0.29552, 0.95534));   // 17.4 degrees

float2x2 mm2(float a) { float c = cos(a), s = sin(a); return float2x2(float2(c, s), float2(-s, c)); }
float2 vxm(float2 v, float2x2 m) { return float2(dot(v, m[0]), dot(v, m[1])); }
float tri(float x) { return clamp(abs(fract(x) - 0.5), 0.01, 0.49); }
float2 tri2(float2 p) { return float2(tri(p.x) + tri(p.y), tri(p.y + tri(p.x))); }
float au_hash21(float2 n) { return fract(sin(dot(n, float2(12.9898, 4.1414))) * 43758.5453); }

float triNoise2d(float2 p, float spd, float time) {
  float z = 1.8;
  float z2 = 1.1;
  float rz = 0.0;
  p = vxm(p, mm2(p.x * 0.06));
  float2 bp = p;
  for (float i = 0.0; i < 5.0; i++) {
    float2 dg = tri2(bp * 1.85) * 0.75;
    dg = vxm(dg, mm2(time * spd));
    p -= dg / z2;

    bp *= 1.3;
    z2 *= 0.45;
    z *= 0.42;
    p *= 1.21 + (rz - 1.0) * 0.02;

    rz += tri(p.x + tri(p.y)) * z;
    p = -vxm(p, m2);
  }
  return clamp(1.0 / pow(rz * 29.0, 1.3), 0.0, 0.55);
}

// slice colour by height index: sine palettes as in the originals, ramps for the two designed ones
float3 sliceColor(float i, int pal) {
  switch (pal) {
    case 1:  return sin(1.0 - float3(2.15, -0.5, 1.2) + i * 0.043) * 0.5 + 0.5;
    case 2:  return mix(float3(0.25, 0.95, 0.35), float3(1.0, 0.22, 0.10), pow(i / 49.0, 0.8));
    case 3:  return mix(float3(1.0, 0.78, 0.25), float3(0.15, 0.85, 0.55), pow(i / 49.0, 1.2));
    default: return sin(2.0 - float3(-10.0, -0.7, 1.3) + i * 0.03) * 0.5 + 0.5;
  }
}

float4 aurora(float3 ro, float3 rd, float2 fragCoord, float time, int pal) {
  float4 col = 0.0;
  float4 avgCol = 0.0;
  for (float i = 0.0; i < 50.0; i++) {
    float of = 0.006 * au_hash21(fragCoord) * smoothstep(0.0, 15.0, i);
    float pt = ((0.8 + pow(i, 1.4) * 0.002) - ro.y) / (rd.y * 2.0 + 0.4);
    pt -= of;
    float3 bpos = ro + pt * rd;
    float2 p = bpos.zx;
    float rzt = triNoise2d(p, 0.06, time);
    float4 col2 = float4(sliceColor(i, pal) * rzt, rzt);
    avgCol = mix(avgCol, col2, 0.5);
    col += avgCol * exp2(-i * 0.065 - 2.5) * smoothstep(0.7, 5.0, i);
  }
  col *= clamp(rd.y * 17.0 + 0.4, 0.0, 1.0);
  return col * 1.8;
}

float3 nmzHash33(float3 q) {
  uint3 p = uint3(int3(q));
  p = p * uint3(374761393u, 1103515245u, 668265263u) + p.zxy + p.yzx;
  p = p.yzx * (p.zxy ^ (p >> 3u));
  return float3(p ^ (p >> 16u)) * (1.0 / float3(0xffffffffu));
}

float3 stars(float3 p, float resx) {
  float3 c = 0.0;
  float res = pow(resx / 400.0, 0.5) * 400.0;
  for (float i = 0.0; i < 4.0; i++) {
    float3 q = fract(p * (0.15 * res)) - 0.5;
    float3 id = floor(p * (0.15 * res));
    float2 rn = nmzHash33(id).xy;
    float c2 = 1.0 - smoothstep(0.0, 0.7, length(q));
    c2 *= step(rn.x, 0.0005 + i * i * 0.001);
    c += c2 * (mix(float3(1.0, 0.49, 0.1), float3(0.75, 0.9, 1.0), rn.y) * 0.1 + 0.9);
    p *= 1.3;
  }
  return c * c * 0.8;
}

// the glow's direction: at this camera's yaw the screen's left-right is world z, so that is
// the component the seed flips to put the wine glow on either side
float3 bg(float3 rd, float side) {
  float sd = dot(normalize(float3(-0.3, -0.6, 0.9 * side)), rd) * 0.5 + 0.5;
  sd = pow(sd, 5.0);
  float3 col = mix(float3(0.1, 0.1, 0.2), float3(0.8, 0.035, 0.15), sd);
  return col * 0.89;
}

float4 wp_main(float2 uv, constant Uniforms& u) {
  float S = u.seed;
  float time = hash11(S) * 600.0 + u.time;
  float hue = hash11(S + 1.0);
  int pal = WP_PARAM_hue >= 0.0 ? int(WP_PARAM_hue) % 4 : (hue < 0.5 ? 0 : 1 + int((hue - 0.5) * 6.0) % 3);
  float yaw = (WP_PARAM_yaw >= 0.0 ? WP_PARAM_yaw : hash11(S + 2.0)) - 0.5;
  float side = hash11(S + 3.0) < 0.5 ? 1.0 : -1.0;
  float3 starOff = float3(hash11(S + 4.0), hash11(S + 5.0), hash11(S + 6.0)) * 4.0 - 2.0;

  float aspect = u.res.x / u.res.y;
  float2 fragCoord = uv * u.res;
  // the original's frame: q.y scaled by aspect, so the horizon sits 0.5/aspect up the screen.
  // on a portrait panel that would climb past the top, so it's held at 42% there
  float horizon = min(0.5 / aspect, 0.42);
  float2 p = float2(uv.x - 0.5, (uv.y - horizon) * aspect);
  float3 ro = float3(0.0, 0.0, -6.7);
  float3 rd = float3(p, 1.3);
  float2 mo = uv + 1.4;
  rd.xz = vxm(rd.xz, mm2(mo.x + sin(time * 0.05) * 0.2 + yaw));

  float fade = smoothstep(0.0, 0.09, abs(rd.y)) * 0.1 + 0.9;

  float3 col;
  if (rd.y > 0.0) {
    float4 aur = smoothstep(float4(0.0), float4(1.5), aurora(ro, rd, fragCoord, time, pal)) * fade;
    col = bg(rd, side) * fade + (1.0 - fade) * float3(0.4);
    rd = normalize(rd);
    col += stars(rd + starOff, u.res.x);
    col = col * (1.0 - aur.a) + aur.rgb;
  } else {   // reflection
    rd.y = abs(rd.y);
    col = bg(rd, side) * fade * 0.6;
    rd = normalize(rd);
    float4 aur = smoothstep(float4(0.0), float4(2.5), aurora(ro, rd, fragCoord, time, pal));
    col += stars(rd + starOff, u.res.x) * 0.1;
    col = col * (1.0 - aur.a) + aur.rgb;
    float3 pos = ro + ((0.5 - ro.y) / rd.y) * rd;
    float nz2 = triNoise2d(pos.xz * float2(0.5, 0.7), 0.0, time);
    col += mix(float3(0.2, 0.25, 0.5) * 0.08, float3(0.3, 0.3, 0.5) * 0.7, nz2 * 0.4);
  }

  col = clamp(col, 0.0, 1.0);
  col += (hash21(uv * u.res + u.seed) - 0.5) * 0.006;
  return float4(col, 1.0);
}
