// after "Monterey wannabe" by mrange, https://www.shadertoy.com/view/NdVfzK (CC0)
//   hsv2rgb: sam hocevar (WTFPL) — the prelude's is the same formula
//   vnoise: iq (MIT), aces_approx: matt taylor, sRGB: nmz
//
// a valley of hills after the macOS monterey wallpaper: 12 flat planes at increasing depth, each a
// value-noise silhouette (5 octaves for the ridge, 2 for a soft glow band under it), alpha-blended
// front to back. hue drifts with distance along a 0.66 -> 1.1 ramp (blue to magenta) and value
// climbs with it, so near hills are dark and the far ones fade toward a pale lavender sky. the camera
// rides a wobbling track down the valley. aces, then sRGB out.
//
// seed: where on the track the camera sits, a hue rotation of the whole palette (kept near the
// original blue/purple for ~40% of seeds), and a noise domain shift so the hills differ too.

// `--set hue=0.15` rotates the palette by that much (about -0.25..0.25 is the seeded range); negative = seeded
#ifndef WP_PARAM_hue
#define WP_PARAM_hue -1.0
#endif
// `--set z=120` puts the camera at that point on the track (0..500 is the seeded range); negative = seeded
#ifndef WP_PARAM_z
#define WP_PARAM_z -1.0
#endif
// `--set speed=0` freezes the stream; the original crawls at 0.3333 units/s
#ifndef WP_PARAM_speed
#define WP_PARAM_speed 0.3333
#endif

float2x2 mt_rot(float a) { return float2x2(float2(cos(a), sin(a)), float2(-sin(a), cos(a))); }

float4 mt_blend(float4 back, float4 front) {
  float w = front.w + back.w * (1.0 - front.w);
  float3 xyz = (front.xyz * front.w + back.xyz * back.w * (1.0 - front.w)) / w;
  return w > 0.0 ? float4(xyz, w) : float4(0.0);
}

float mt_srgb(float t) { return mix(1.055 * pow(t, 1.0 / 2.4) - 0.055, 12.92 * t, step(t, 0.0031308)); }
float3 mt_srgb(float3 c) { return float3(mt_srgb(c.x), mt_srgb(c.y), mt_srgb(c.z)); }

float3 mt_aces(float3 v) {
  v = max(v, 0.0) * 0.6;
  return clamp((v * (2.51 * v + 0.03)) / (v * (2.43 * v + 0.59) + 0.14), 0.0, 1.0);
}

float mt_tanh(float x) {
  float x2 = x * x;
  return clamp(x * (27.0 + x2) / (27.0 + 9.0 * x2), -1.0, 1.0);
}

// the source's own sin hash and value noise, kept so the hills keep their shape
float mt_hash(float2 p) {
  float a = dot(p, float2(127.1, 311.7));
  return fract(sin(a) * 43758.5453123);
}

float mt_vnoise(float2 p) {
  float2 i = floor(p), f = fract(p);
  float2 u = f * f * (3.0 - 2.0 * f);
  float a = mt_hash(i), b = mt_hash(i + float2(1.0, 0.0)), c = mt_hash(i + float2(0.0, 1.0)), d = mt_hash(i + float2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// hills climb away from the valley's centre line
float mt_heightFactor(float2 p) { return 2.0 * smoothstep(0.0, 1.25, abs(p.x) - 0.05) + 1.0; }

// dom shifts the noise only; the height factor still reads the valley's own x
float mt_fbm(float2 p, int octaves, float2 dom) {
  float hf = mt_heightFactor(p);
  float sum = 0.0, a = 1.0;
  p += dom;
  for (int i = 0; i < octaves; ++i) {
    sum += a * mt_vnoise(p);
    a *= 0.5;
    p *= 2.0;
  }
  return hf * sum;
}

// the camera track: a slow lissajous wobble around the valley axis
float3 mt_offset(float z) {
  float a = z * 0.5;
  float2 p = float2(0.33, 0.1) * (float2(cos(a), sin(a * sqrt(2.0))) + float2(cos(a * sqrt(0.75)), sin(a * sqrt(0.5))));
  return float3(p, z);
}

float3 mt_doffset(float z) {
  float eps = 0.1;
  return 0.5 * (mt_offset(z + eps) - mt_offset(z - eps)) / (2.0 * eps);
}

float3 mt_ddoffset(float z) {
  float eps = 0.1;
  return 0.5 * (mt_doffset(z + eps) - mt_doffset(z - eps)) / (2.0 * eps);
}

// one hill plane: silhouette coverage in alpha, a glow band under the ridge from the low-octave height
float4 mt_plane(float3 ro, float3 pp, float3 npp, float3 off, float2 dom, float hueOff) {
  float2 p = (pp - off * 2.0 * float3(1.0, 1.0, 0.0)).xy;

  const float2 stp = float2(0.5, 0.33);
  float2 np = float2(p.x, pp.z) * stp;
  float he = mt_fbm(np, 5, dom) - 1.8;
  float lohe = mt_fbm(np, 2, dom) - 2.15;

  float d = p.y - he;
  float lod = p.y - lohe;

  float aa = distance(pp, npp) * sqrt(1.0 / 3.0);

  float df = mt_tanh(max(0.225 * distance(ro, pp) - 0.4, 0.0));
  float hf = mix(0.66, 1.1, df) + hueOff;
  float gf = mt_tanh(exp(-2.0 * lod));
  float yf = smoothstep(2.5, -1.0, pp.y);
  float3 acol = hsv2rgb(float3(hf, 1.0, mix(0.2, 1.0, df)));
  float3 gcol = hsv2rgb(float3(hf, 1.0, 1.0 - gf));

  float t = smoothstep(aa, -aa, d);
  t *= mix(1.0, yf, sqrt(df));
  t = max(t, gf * yf * yf);
  return float4(acol + 0.5 * gcol, t);
}

float3 mt_color(float3 ww, float3 uu, float3 vv, float3 ro, float2 p, float resY, float2 dom, float hueOff) {
  float2 np = p + 2.0 / resY;
  const float rdd = 2.0;
  float3 rd = normalize(-p.x * uu + p.y * vv + rdd * ww);
  float3 nrd = normalize(-np.x * uu + np.y * vv + rdd * ww);

  const float planeDist = 0.6;
  const int furthest = 12;
  const int fadeFrom = furthest - 3;
  const float fadeDist = planeDist * float(fadeFrom);
  const float maxDist = planeDist * float(furthest);
  float nz = floor(ro.z / planeDist);

  float3 skyCol = hsv2rgb(float3(0.66 + hueOff, 0.2, 1.0));

  float4 acol = float4(0.0);
  const float cutOff = 0.995;

  for (int i = 1; i <= furthest; ++i) {
    float pz = planeDist * nz + planeDist * float(i);
    float pd = (pz - ro.z) / rd.z;
    float3 pp = ro + rd * pd;

    if (pd > 0.0 && acol.w < cutOff) {
      float3 npp = ro + nrd * pd;
      float3 off = mt_offset(pp.z);
      float4 pcol = mt_plane(ro, pp, npp, off, dom, hueOff);
      float fadeIn = smoothstep(maxDist, fadeDist, pd);
      float fadeOut = smoothstep(0.0, planeDist, pd);
      pcol.w *= fadeIn * fadeOut;
      acol = mt_blend(pcol, acol);
    } else {
      acol.w = acol.w > cutOff ? 1.0 : acol.w;
      break;
    }
  }

  return mix(skyCol, acol.xyz, acol.w);
}

float4 wp_main(float2 uv, constant Uniforms& u) {
  float S = u.seed;
  float2 p = -1.0 + 2.0 * uv;
  p.x *= u.res.x / u.res.y;

  // the seed picks a spot on the track, a palette rotation and a noise domain shift
  float z = (WP_PARAM_z >= 0.0 ? WP_PARAM_z : hash11(S) * 500.0) + u.time * WP_PARAM_speed;
  float hr = hash11(S + 1.0);
  float hueOff = hr < 0.4 ? (hr / 0.4 - 0.5) * 0.04 : mix(-0.25, 0.25, (hr - 0.4) / 0.6);
  if (WP_PARAM_hue >= 0.0) hueOff = WP_PARAM_hue;
  float2 dom = float2(hash11(S + 2.0), hash11(S + 3.0)) * 100.0;

  float2x2 rot = mt_rot(0.1);
  float3 ro = mt_offset(z);
  float3 dro = mt_doffset(z);
  float3 ddro = mt_ddoffset(z);
  dro.zy = dro.zy * rot;
  float3 ww = normalize(dro);
  float3 uu = normalize(cross(normalize(float3(0.0, 1.0, 0.0) + 2.0 * ddro), ww));
  float3 vv = cross(ww, uu);

  float3 col = mt_color(ww, uu, vv, ro, p, u.res.y, dom, hueOff);
  col = mt_aces(col);
  col = mt_srgb(col);
  col += (hash21(uv * u.res + u.seed) - 0.5) * 0.006;
  return float4(clamp(col, 0.0, 1.0), 1.0);
}
