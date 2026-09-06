// neon isolines on a dark plane. after tylermw's rayrender scene, minus the pathtracer.

float3 palette(float t, float baseHue) {
  return hsv2rgb(float3(fract(baseHue + t * 0.25), 0.8, 1.0));
}

float4 wp_main(float2 uv, constant Uniforms& u) {
  float aspect = u.res.x / u.res.y;
  float2 p = (uv - 0.5) * float2(aspect, 1.0);
  float baseHue = hash11(u.seed);
  float2 so = float2(hash11(u.seed + 1.0), hash11(u.seed + 2.0)) * 200.0;

  // camera: low, pitched gently down, looking toward -z. horizon lands ~74% up the frame
  float3 ro = float3(0.0, 1.2, 0.0);
  float pitch = -0.17;
  float3 rd0 = normalize(float3(p.x, p.y, -1.4));
  float cp = cos(pitch), sp = sin(pitch);
  float3 rd = float3(rd0.x, rd0.y * cp - rd0.z * sp, rd0.y * sp + rd0.z * cp);

  bool ground = rd.y < -0.001;
  float t = ground ? -ro.y / rd.y : 400.0;
  float3 hit = ro + rd * t;

  float2 q = hit.xz * 0.11 + so;
  float footprint = max(fwidth(q.x), fwidth(q.y));
  // 5-octave fbm lives roughly in [0.2, 0.8]; stretch it to ~[0, 1] so the contour count is predictable
  float h = (fbm_lod(q, 5, footprint) - 0.22) / 0.56;

  // major + minor isolines. fwidth keeps width constant in screen px; lines fade out where they'd alias
  float levels = 5.0;
  float f = h * levels;
  float fw = max(fwidth(f), 1e-4);
  float d = min(fract(f), 1.0 - fract(f));
  float aliasFade = 1.0 - smoothstep(0.18, 0.45, fw);
  float major = (1.0 - smoothstep(0.0, fw * 1.5, d)) * aliasFade;
  float glow = (exp(-d / (fw * 5.0)) * 0.45 + exp(-d * 6.0) * 0.012) * aliasFade;

  float f2 = f * 2.0;
  float fw2 = max(fwidth(f2), 1e-4);
  float d2 = min(fract(f2), 1.0 - fract(f2));
  float minor = (1.0 - smoothstep(0.0, fw2 * 1.2, d2)) * (1.0 - smoothstep(0.15, 0.4, fw2)) * 0.25;

  float level = clamp(floor(f) / levels, 0.0, 1.0);
  float3 lineCol = palette(level, baseHue);

  float2 g = abs(fract(hit.xz * 0.25) - 0.5);
  float2 gw = fwidth(hit.xz * 0.25);
  float grid = 1.0 - smoothstep(0.0, max(gw.x, gw.y) * 1.5, min(g.x, g.y));
  float3 gridCol = palette(0.5, baseHue) * 0.02;

  float3 skyBase = float3(0.0015, 0.0015, 0.004);
  float3 horizonGlow = palette(0.0, baseHue) * 0.05;
  float3 fogCol = skyBase + horizonGlow;

  float fog = 1.0 - exp(-t * 0.03);
  float3 groundCol = lineCol * (major * 1.1 + minor + glow) + gridCol * grid;
  groundCol += float3(0.003, 0.0025, 0.005);
  groundCol = mix(groundCol, fogCol, fog);

  float3 sky = skyBase + horizonGlow * exp(-max(rd.y, 0.0) * 28.0);
  // quantize by angle, not by plane projection, so cells don't stretch into streaks at the horizon
  float2 sc = floor(float2(atan2(rd.x, -rd.z), asin(clamp(rd.y, -1.0, 1.0))) * 320.0);
  float star = step(0.9965, hash21(sc + so)) * smoothstep(0.015, 0.1, rd.y);
  sky += star * 0.35;

  float3 col = ground ? groundCol : sky;
  col = col / (1.0 + col);
  col *= 1.0 - 0.35 * dot(uv - 0.5, uv - 0.5);
  col = pow(max(col, 0.0), float3(1.0 / 2.2));
  col += (hash21(uv * u.res + u.seed) - 0.5) * 0.006;
  return float4(col, 1.0);
}
