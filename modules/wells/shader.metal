// gravity wells, after mjmurdoc: a gravitational potential surface raymarched in perspective,
// isolines drawn on the surface, colour ramped by depth so each bowl glows from its floor,
// emissive bodies, near-massless satellites, orbit rings and a dashed web as real 3D curves.

#define MAX_BODIES 7
#define MAX_RINGS 3
#define MAX_SATS 12

// camera overrides: `wp gen wells --set el=0.12 --set dist=6 --set az=1.5`; negative = seeded
#ifndef WP_PARAM_el
#define WP_PARAM_el -1.0
#endif
#ifndef WP_PARAM_dist
#define WP_PARAM_dist -1.0
#endif
#ifndef WP_PARAM_az
#define WP_PARAM_az -1.0
#endif

struct Body {
  float3 pos;
  float mass;
  float radius;
  float soft;
  float3 core;
  int rings;
  float ringA[MAX_RINGS], ringB[MAX_RINGS], ringY[MAX_RINGS];
  float rot;
};

struct Sat {
  float3 pos;
  float mass, radius, soft;
  int parent;
};

struct Palette {
  float3 bg, line, lineHot, dash, orbit, coreWhite, warm, hot;
  float lineAlpha;
};

Palette palette(int i) {
  Palette p;
  p.lineAlpha = 0.85;
  switch (i) {
    case 0:  // ember on teal: green sheet, red -> orange -> yellow floors
      p.bg = float3(0.004, 0.016, 0.014); p.line = float3(0.55, 0.62, 0.55); p.lineHot = float3(0.95, 0.85, 0.6);
      p.dash = float3(0.90, 0.45, 0.40); p.orbit = float3(0.85, 0.70, 0.35); p.coreWhite = float3(1.0, 0.95, 0.75);
      p.warm = float3(0.55, 0.06, 0.02); p.hot = float3(1.0, 0.55, 0.10); break;
    case 1:  // ink: gray lines, red floors
      p.bg = float3(0.004, 0.004, 0.005); p.line = float3(0.42, 0.43, 0.45); p.lineHot = float3(0.9, 0.7, 0.65);
      p.dash = float3(0.85, 0.20, 0.18); p.orbit = float3(0.55, 0.55, 0.55); p.coreWhite = float3(1.0, 0.92, 0.92);
      p.warm = float3(0.30, 0.02, 0.02); p.hot = float3(1.0, 0.25, 0.12); p.lineAlpha = 0.7; break;
    case 2:  // neon: green contours turning cyan, blue floors
      p.bg = float3(0.002, 0.005, 0.018); p.line = float3(0.15, 0.85, 0.40); p.lineHot = float3(0.45, 1.0, 1.0);
      p.dash = float3(0.25, 0.40, 0.95); p.orbit = float3(0.30, 0.80, 0.95); p.coreWhite = float3(0.92, 0.98, 1.0);
      p.warm = float3(0.02, 0.10, 0.60); p.hot = float3(0.15, 0.55, 1.0); p.lineAlpha = 0.9; break;
    case 3:  // gold on navy, salmon dashes, orange floors
      p.bg = float3(0.010, 0.010, 0.024); p.line = float3(0.42, 0.46, 0.70); p.lineHot = float3(0.95, 0.85, 0.65);
      p.dash = float3(0.95, 0.40, 0.30); p.orbit = float3(0.90, 0.75, 0.40); p.coreWhite = float3(1.0, 0.96, 0.80);
      p.warm = float3(0.45, 0.10, 0.04); p.hot = float3(1.0, 0.50, 0.18); p.lineAlpha = 0.7; break;
    default: // magenta on violet, cyan orbits, pink floors
      p.bg = float3(0.012, 0.003, 0.018); p.line = float3(0.50, 0.38, 0.70); p.lineHot = float3(1.0, 0.75, 0.95);
      p.dash = float3(0.30, 0.90, 0.95); p.orbit = float3(0.35, 0.95, 0.95); p.coreWhite = float3(1.0, 0.90, 1.0);
      p.warm = float3(0.40, 0.02, 0.30); p.hot = float3(1.0, 0.25, 0.70); p.lineAlpha = 0.75; break;
  }
  return p;
}

// the potential: softened 1/r wells, summed over bodies and satellites. always <= 0, flat far away
float potential(float2 xz, thread const Body* b, int n, thread const Sat* s, int ns) {
  float h = 0.0;
  for (int i = 0; i < n; i++) {
    float2 d = xz - b[i].pos.xz;
    h -= b[i].mass * 0.35 / sqrt(dot(d, d) + b[i].soft * b[i].soft);
  }
  for (int i = 0; i < ns; i++) {
    float2 d = xz - s[i].pos.xz;
    h -= s[i].mass * 0.35 / sqrt(dot(d, d) + s[i].soft * s[i].soft);
  }
  return h;
}

float2 gradient(float2 xz, thread const Body* b, int n, thread const Sat* s, int ns) {
  float e = 0.006;
  return float2(potential(xz + float2(e, 0), b, n, s, ns) - potential(xz - float2(e, 0), b, n, s, ns),
                potential(xz + float2(0, e), b, n, s, ns) - potential(xz - float2(0, e), b, n, s, ns)) / (2.0 * e);
}

// ray/sphere with an anti-aliased edge: cov is how much of this pixel the sphere covers, from
// the ray's closest approach to the centre measured against half a pixel at that depth
float sphereHit(float3 ro, float3 rd, float3 c, float r, float pxPerUnit, thread float& cov) {
  float3 oc = ro - c;
  float b = dot(oc, rd);
  if (b >= 0.0) return -1.0;
  float dperp = sqrt(max(dot(oc, oc) - b * b, 0.0));
  float px = 0.5 * -b / pxPerUnit;
  cov = 1.0 - smoothstep(r - px, r + px, dperp);
  if (cov <= 0.0) return -1.0;
  return -b - sqrt(max(r * r - dperp * dperp, 0.0));
}

float2 ringPoint(thread const Body& b, int k, float ang) {
  float2 loc = float2(cos(ang) * b.ringA[k], sin(ang) * b.ringB[k]);
  float cr = cos(b.rot), sr = sin(b.rot);
  return b.pos.xz + float2(loc.x * cr - loc.y * sr, loc.x * sr + loc.y * cr);
}

// closest approach between the ray and segment ab: returns the distance, with the ray and
// segment parameters through out-params
float raySegment(float3 ro, float3 rd, float3 a, float3 b, thread float& s, thread float& u) {
  float3 ab = b - a, ao = ro - a;
  float bb = dot(rd, ab), c = dot(ab, ab), d = dot(rd, ao), e = dot(ab, ao);
  float denom = max(c - bb * bb, 1e-6);
  u = clamp((e - bb * d) / denom, 0.0, 1.0);
  float3 p = a + ab * u;
  s = max(dot(p - ro, rd), 0.0);
  return length(ro + rd * s - p);
}

float4 wp_main(float2 uv, constant Uniforms& u) {
  float aspect = u.res.x / u.res.y;
  float S = u.seed;
  float r0 = hash11(S), r1 = hash11(S + 1.0), r2 = hash11(S + 2.0), r3 = hash11(S + 3.0);

  Palette pal = palette(int(hash11(S + 4.0) * 5.0) % 5);

  // bodies: a loose cluster, one of them often dominant
  int n = 3 + int(hash11(S + 5.0) * 5.0);
  Body bodies[MAX_BODIES];
  float3 center = 0.0;
  for (int i = 0; i < n; i++) {
    float k = float(i) * 7.31 + S;
    float a = hash11(k + 1.0) * 6.2831853, rad = 1.2 + hash11(k + 2.0) * 3.4;
    float2 xz = float2(cos(a), sin(a)) * rad * float2(1.4, 1.0);
    float m = 0.35 + pow(hash11(k + 3.0), 2.2) * 1.8;
    if (i == 0 && r0 < 0.5) m = 1.6 + hash11(k + 3.5) * 1.0;
    bodies[i].mass = m;
    bodies[i].radius = 0.06 + m * 0.045;
    bodies[i].soft = bodies[i].radius * 5.5;   // wide bowls rather than funnels
    bodies[i].pos = float3(xz.x, 0.0, xz.y);
    bodies[i].core = pal.coreWhite;
    float rr = hash11(k + 5.0);
    bodies[i].rings = rr < 0.3 ? 0 : (rr < 0.6 ? 1 : (rr < 0.85 ? 2 : 3));
    for (int q = 0; q < MAX_RINGS; q++) {
      bodies[i].ringA[q] = bodies[i].radius * (3.0 + float(q) * 2.4 + hash11(k + 6.0 + float(q)) * 1.6);
      bodies[i].ringB[q] = bodies[i].ringA[q] * (0.55 + hash11(k + 9.0 + float(q)) * 0.45);
    }
    bodies[i].rot = hash11(k + 8.0) * 3.1416;
    center += bodies[i].pos;
  }
  center /= float(n);

  // satellites: 0-3 per ring, sharing rings. nearly massless — a shallow dimple, never a pit
  Sat sats[MAX_SATS];
  int ns = 0;
  for (int i = 0; i < n; i++) {
    for (int q = 0; q < bodies[i].rings; q++) {
      float kq = S + float(i) * 13.7 + float(q) * 3.1;
      float c = hash11(kq);
      int count = c < 0.35 ? 0 : (c < 0.65 ? 1 : (c < 0.88 ? 2 : 3));
      for (int s = 0; s < count && ns < MAX_SATS; s++) {
        float ks = kq + float(s) * 1.7 + 0.5;
        float2 xz = ringPoint(bodies[i], q, hash11(ks) * 6.2831853);
        sats[ns].pos = float3(xz.x, 0.0, xz.y);
        sats[ns].radius = 0.016 + hash11(ks + 1.0) * 0.02;
        sats[ns].mass = 0.006 + hash11(ks + 2.0) * 0.014;
        sats[ns].soft = sats[ns].radius * 8.0;
        sats[ns].parent = i;
        ns++;
      }
    }
  }
  // bodies settle just above the floor of their own bowl; each ring floats just above the highest
  // point of the sheet beneath it, so it rests in the bowl and never sinks into a neighbour's wall
  for (int i = 0; i < n; i++) {
    bodies[i].pos.y = potential(bodies[i].pos.xz, bodies, n, sats, ns) + bodies[i].radius * 0.9;
    for (int q = 0; q < bodies[i].rings; q++) {
      float top = -1e9;
      for (int a = 0; a < 16; a++) {
        top = max(top, potential(ringPoint(bodies[i], q, float(a) * 0.39269908), bodies, n, sats, ns));
      }
      bodies[i].ringY[q] = top + 0.03;
    }
  }
  for (int i = 0; i < ns; i++) {
    // find the ring this satellite was placed on and sit on it
    int p = sats[i].parent;
    float best = 1e9, y = 0.0;
    for (int q = 0; q < bodies[p].rings; q++) {
      float2 d = sats[i].pos.xz - bodies[p].pos.xz;
      float cr = cos(-bodies[p].rot), sr = sin(-bodies[p].rot);
      float2 loc = float2(d.x * cr - d.y * sr, d.x * sr + d.y * cr);
      float err = abs(length(loc / float2(bodies[p].ringA[q], bodies[p].ringB[q])) - 1.0);
      if (err < best) { best = err; y = bodies[p].ringY[q]; }
    }
    sats[i].pos.y = y + sats[i].radius;
  }

  // camera: far and high over the cluster, close and medium, or grazing — down at the sheet
  // with bodies clipping the horizon
  bool graze = r1 < 0.25, close = r1 < 0.55;
  float dist = WP_PARAM_dist >= 0.0 ? WP_PARAM_dist : (graze ? 2.6 + r2 * 2.0 : close ? 3.2 + r2 * 2.5 : 7.5 + r2 * 6.0);
  float el = WP_PARAM_el >= 0.0 ? WP_PARAM_el : (graze ? 0.07 + r3 * 0.13 : (close ? 0.22 : 0.42) + r3 * 0.36);
  float az = WP_PARAM_az >= 0.0 ? WP_PARAM_az : hash11(S + 6.0) * 6.2831853;
  float3 target = center + float3(hash11(S + 7.0) - 0.5, 0.0, hash11(S + 8.0) - 0.5) * (close ? 2.5 : 1.0);
  target.y = graze ? -0.3 : (close ? -0.4 : -0.2);
  float3 ro = target + dist * float3(cos(el) * sin(az), sin(el), cos(el) * cos(az));
  float3 fwd = normalize(target - ro);
  float3 right = normalize(cross(fwd, float3(0, 1, 0)));
  float3 up = cross(right, fwd);
  float fov = close ? 0.62 : 0.55;
  float tanHalf = tan(fov * 0.5);
  float2 p = (uv - 0.5) * 2.0 * float2(aspect, 1.0) * tanHalf;
  float3 rd = normalize(fwd + right * p.x + up * p.y);
  float pxPerUnit = u.res.y / (2.0 * tanHalf);   // world -> pixels at distance 1

  // spheres first: bodies and their satellites
  float tS = 1e9, sphereCov = 0.0;
  float3 sphereCol = 0.0;
  for (int i = 0; i < n; i++) {
    float cov;
    float t = sphereHit(ro, rd, bodies[i].pos, bodies[i].radius, pxPerUnit, cov);
    if (t > 0.0 && t < tS) {
      tS = t;
      sphereCov = cov;
      float3 nrm = normalize(ro + rd * t - bodies[i].pos);
      float rim = pow(1.0 - max(0.0, dot(nrm, -rd)), 2.0);
      sphereCol = mix(bodies[i].core * 1.6, pal.hot * 2.0, rim * 0.7);
    }
  }
  for (int i = 0; i < ns; i++) {
    float cov;
    float t = sphereHit(ro, rd, sats[i].pos, sats[i].radius, pxPerUnit, cov);
    if (t > 0.0 && t < tS) {
      tS = t;
      sphereCov = cov;
      float3 nrm = normalize(ro + rd * t - sats[i].pos);
      float3 parentPos = bodies[sats[i].parent].pos;
      float lit = 0.35 + 0.65 * max(0.0, dot(nrm, normalize(parentPos - sats[i].pos)));
      sphereCol = mix(float3(0.55, 0.55, 0.6), pal.hot, 0.3) * lit * 1.2;
    }
  }

  // raymarch the sheet. the potential is never above 0, so a rising ray above it can't hit
  float t = 0.0, tPrev = 0.0;
  bool hit = false;
  for (int i = 0; i < 240; i++) {
    float3 q = ro + rd * t;
    if (q.y > 0.04 && rd.y > 0.0) break;
    float dh = q.y - potential(q.xz, bodies, n, sats, ns);
    if (dh < 0.0015) { hit = true; break; }
    tPrev = t;
    t += clamp(dh * 0.45, 0.004, 0.5);
    if ((sphereCov >= 1.0 && t > tS) || t > 70.0) break;   // a partly covered rim still needs the sheet behind it
  }
  if (hit) {
    float lo = tPrev, hi = t;
    for (int i = 0; i < 6; i++) {
      float mid = 0.5 * (lo + hi);
      float3 q = ro + rd * mid;
      if (q.y - potential(q.xz, bodies, n, sats, ns) < 0.0) hi = mid; else lo = mid;
    }
    t = 0.5 * (lo + hi);
  }

  float3 sky = pal.bg * 0.3;
  float3 col = sky;
  bool sphereFront = tS < t || (!hit && tS < 1e8);
  float tLimit = sphereFront ? tS : (hit ? t : 1e9);
  if (hit) {
    float3 q = ro + rd * t;
    float h = potential(q.xz, bodies, n, sats, ns);
    float2 g = gradient(q.xz, bodies, n, sats, ns);
    float3 nrm = normalize(float3(-g.x, 1.0, -g.y));
    float facing = max(0.25, abs(dot(nrm, -rd)));
    float pixelWorld = t / pxPerUnit;

    // the sheet's colour is a ramp on depth into the nearest bowl: flat = background, warming
    // as it drops, hot on the floor. depth is each body's own well normalised to its peak, so
    // a cluster's shared depression stays dark and only the bowls glow, banded by the rings
    float depth = 0.0;
    for (int i = 0; i < n; i++) {
      float2 d = q.xz - bodies[i].pos.xz;
      float w = bodies[i].soft / sqrt(dot(d, d) + bodies[i].soft * bodies[i].soft);
      depth += w * w * w * w;
    }
    for (int i = 0; i < ns; i++) {
      float2 d = q.xz - sats[i].pos.xz;
      float w = sats[i].soft / sqrt(dot(d, d) + sats[i].soft * sats[i].soft) * 0.6;
      depth += w * w * w * w;
    }
    depth = pow(depth, 0.25);
    float lambert = max(0.0, dot(nrm, normalize(float3(0.3, 1.0, 0.25))));
    col = pal.bg * (0.5 + 0.5 * lambert);
    col = mix(col, pal.warm, smoothstep(0.25, 0.6, depth));
    col = mix(col, pal.hot, smoothstep(0.6, 1.0, depth) * 0.85);

    // isolines of the potential, constant width in screen pixels, brightening with depth
    float levels = 16.0;
    float f = h * levels;
    float fw = levels * length(g) * pixelWorld / facing + 1e-5;
    float dl = min(fract(f), 1.0 - fract(f));
    float line = 1.0 - smoothstep(0.3 * fw, 1.2 * fw, dl);
    float crowd = 1.0 - smoothstep(0.28, 0.55, fw);
    // contours brighten down the bowl, then go dark on the hot floor so they stay legible
    float3 lineCol = mix(pal.line, pal.lineHot, smoothstep(0.2, 0.6, depth));
    lineCol = mix(lineCol, pal.warm * 0.7, smoothstep(0.7, 1.0, depth));

    // optional disc edge: the sheet fades to nothing past a radius
    float edge = 1.0;
    if (hash11(S + 9.0) < 0.55) {
      float R = 5.0 + hash11(S + 10.0) * 4.0;
      edge = 1.0 - smoothstep(R - 1.8, R + 0.3, length(q.xz - center.xz));
    }
    float fog = exp(-t * 0.055);

    col = mix(col, lineCol, line * crowd * pal.lineAlpha * fog);
    col *= edge;
    col = mix(col, pal.bg * 0.35, 1.0 - fog);
  }

  // orbit rings: ellipses floating in a horizontal plane, hidden wherever the sheet is nearer
  float orbit = 0.0, orbitFog = 1.0;
  for (int i = 0; i < n; i++) {
    float cr = cos(-bodies[i].rot), sr = sin(-bodies[i].rot);
    for (int k = 0; k < bodies[i].rings; k++) {
      if (abs(rd.y) < 1e-4) continue;
      float tp = (bodies[i].ringY[k] - ro.y) / rd.y;
      if (tp <= 0.0 || tp > tLimit) continue;
      float2 d = (ro + rd * tp).xz - bodies[i].pos.xz;
      float2 loc = float2(d.x * cr - d.y * sr, d.x * sr + d.y * cr);
      float a = bodies[i].ringA[k], b = bodies[i].ringB[k];
      float dist = abs(length(loc / float2(a, b)) - 1.0) * min(a, b);
      float lw = tp / pxPerUnit * 1.3 / sqrt(max(abs(rd.y), 0.05));
      float cov = 1.0 - smoothstep(0.4 * lw, 1.4 * lw, dist);
      if (cov > orbit) { orbit = cov; orbitFog = exp(-tp * 0.055); }
    }
  }
  col = mix(col, pal.orbit, orbit * 0.9 * orbitFog);

  // dashed web: a string laid from each body to its nearest earlier body — straight where it can
  // be, draped over the sheet where the straight line would cut through the ridge between bowls
  float dash = 0.0, dashFog = 1.0;
  for (int i = 1; i < n; i++) {
    int j = 0;
    float best = 1e9;
    for (int k = 0; k < i; k++) {
      float dk = length(bodies[i].pos.xz - bodies[k].pos.xz);
      if (dk < best) { best = dk; j = k; }
    }
    float3 a = bodies[i].pos + float3(0, bodies[i].radius * 0.6, 0);
    float3 b = bodies[j].pos + float3(0, bodies[j].radius * 0.6, 0);
    float s, uu;
    if (raySegment(ro, rd, a, b, s, uu) > 2.0) continue;   // the drape lifts it, but not that far
    const int K = 24;
    float3 prev = a;
    for (int k = 1; k <= K; k++) {
      float3 c = mix(a, b, float(k) / float(K));
      c.y = max(c.y, potential(c.xz, bodies, n, sats, ns) + 0.025);
      float d = raySegment(ro, rd, prev, c, s, uu);
      float along = (float(k - 1) + uu) / float(K);
      prev = c;
      if (s > tLimit) continue;
      float lw = s / pxPerUnit * 1.3;
      float on = step(fract(along * best / 0.22), 0.55);
      float cov = (1.0 - smoothstep(0.4 * lw, 1.4 * lw, d)) * on;
      if (cov > dash) { dash = cov; dashFog = exp(-s * 0.055); }
    }
  }
  col = mix(col, pal.dash, dash * 0.85 * dashFog);

  // spheres go on last so their anti-aliased rims blend over whatever is behind them
  if (sphereFront) col = mix(col, sphereCol, sphereCov);

  // bloom: screen-space halos around every body the camera can actually see. a lens halo is all
  // or nothing, so the test is a shadow ray from the camera to the body, shared by every pixel
  for (int i = 0; i < n; i++) {
    float3 v = bodies[i].pos - ro;
    float z = dot(v, fwd);
    if (z <= 0.1) continue;
    float2 sp = float2(dot(v, right), dot(v, up)) / (z * tanHalf);
    float2 spx = (sp / float2(aspect, 1.0) * 0.5 + 0.5) * u.res;
    float dpx = length(uv * u.res - spx);
    float rpx = bodies[i].radius / (z * tanHalf) * u.res.y * 0.5;
    // only pay for the shadow ray where the halo reaches, and fade it out toward that reach
    float reach = max(rpx * 14.0, 40.0);
    if (dpx > reach) continue;
    float fade = 1.0 - smoothstep(reach * 0.45, reach, dpx);
    float len = length(v);
    float3 dir = v / len;
    bool visible = true;
    for (int s = 1; s < 40; s++) {
      float tt = len * float(s) / 40.0;
      if (tt > len - bodies[i].radius) break;
      float3 q = ro + dir * tt;
      if (q.y < potential(q.xz, bodies, n, sats, ns)) { visible = false; break; }
    }
    if (!visible) continue;
    float tight = 1.0 / (1.0 + pow(dpx / max(rpx * 0.9, 2.0), 2.0));
    float wide = 1.0 / (1.0 + pow(dpx / max(rpx * 3.0, 6.0), 3.0));
    col += (bodies[i].core * tight * 0.35 + pal.hot * wide * 0.04 * bodies[i].mass) * fade;
  }

  col *= 1.0 - 0.3 * dot(uv - 0.5, uv - 0.5);
  col = col / (1.0 + col * 0.35);
  col = pow(max(col, 0.0), float3(1.0 / 2.2));
  col += (hash21(uv * u.res + S) - 0.5) * 0.008;
  return float4(min(col, 1.0), 1.0);
}
