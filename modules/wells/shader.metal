// gravity wells, after mjmurdoc: a gravitational potential surface raymarched in perspective,
// isolines drawn on the surface, colour ramped by depth so each bowl glows from its floor,
// emissive bodies, near-massless satellites, orbit rings and a dashed web as real 3D curves.
// two passes: wp_main renders linear colour with the ray depth in alpha; wp_post applies depth
// of field, then the screen-space callouts, then vignette, tonemap and grain.

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
// `--set three=1` forces the two-body / lagrange scene, `three=0` the n-body cluster; negative = seeded
#ifndef WP_PARAM_three
#define WP_PARAM_three -1.0
#endif
// `--set dof=0` turns depth of field off, `dof=1` is the strongest; negative = seeded by shot
#ifndef WP_PARAM_dof
#define WP_PARAM_dof -1.0
#endif
// animation: `speed` scales every orbit's clock, `spin` is the camera's drift in radians per second
// (0 for a display that would rather the frame held still)
#ifndef WP_PARAM_speed
#define WP_PARAM_speed 1.0
#endif
#ifndef WP_PARAM_spin
#define WP_PARAM_spin -1.0   // negative = 0.02 rad/s, or 0.05 in ink mode
#endif
// `--set ink=1`: for a 1-bit e-paper panel. paper-white sheet, black contours, bowls darkening to
// black at the floor, white bodies with a dark rim, big massless satellite dots, a slow camera
// drift so the frame visibly moves; no depth of field, no tonemap. `ink=2` is the same print
// white on black
#ifndef WP_PARAM_ink
#define WP_PARAM_ink 0.0
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
  int parent, ring;   // ring: which of the parent's ellipses it orbits on (-1 for a trojan)
};

struct Palette {
  float3 bg, line, lineHot, dash, orbit, coreWhite, warm, hot;
  float lineAlpha;
};

Palette palette(int i) {
  Palette p;
  p.lineAlpha = 0.85;
  if (WP_PARAM_ink > 1.5) {   // ink=2: the same print, white on black
    p.bg = 0.0; p.line = 1.0; p.lineHot = 0.9; p.dash = 0.8; p.orbit = 0.9; p.coreWhite = 1.0;
    p.warm = 0.3; p.hot = 1.0; p.lineAlpha = 1.0;
    return p;
  }
  if (WP_PARAM_ink > 0.5) {   // ink=1: black on white
    p.bg = 1.0; p.line = 0.0; p.lineHot = 0.1; p.dash = 0.2; p.orbit = 0.1; p.coreWhite = 1.0;
    p.warm = 0.75; p.hot = 0.0; p.lineAlpha = 1.0;
    return p;
  }
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

// the frame the sheet is drawn in. the n-body cluster is inertial (w2 = 0): softened 1/r wells,
// always <= 0, flat far away. the two-body scene is its co-rotating frame: the centrifugal term
// makes the sheet the effective potential, whose saddles and hilltops are the lagrange points;
// phi0 lifts the hilltops to height 0 so the sheet still has a ceiling
struct Frame {
  float2 bary;
  float w2;
  float phi0;
};

float potential(float2 xz, thread const Body* b, int n, thread const Sat* s, int ns, Frame fr) {
  float h = -fr.phi0;
  for (int i = 0; i < n; i++) {
    float2 d = xz - b[i].pos.xz;
    h -= b[i].mass * 0.35 / sqrt(dot(d, d) + b[i].soft * b[i].soft);
  }
  for (int i = 0; i < ns; i++) {
    float2 d = xz - s[i].pos.xz;
    h -= s[i].mass * 0.35 / sqrt(dot(d, d) + s[i].soft * s[i].soft);
  }
  float2 c = xz - fr.bary;
  h -= 0.5 * fr.w2 * dot(c, c);
  return h;
}

float2 gradient(float2 xz, thread const Body* b, int n, thread const Sat* s, int ns, Frame fr) {
  float e = 0.006;
  return float2(potential(xz + float2(e, 0), b, n, s, ns, fr) - potential(xz - float2(e, 0), b, n, s, ns, fr),
                potential(xz + float2(0, e), b, n, s, ns, fr) - potential(xz - float2(0, e), b, n, s, ns, fr)) / (2.0 * e);
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

// the rings are kepler ellipses: the body sits at a focus, not the centre, so the ellipse's
// centre is a·e back along the major axis. eccentricity from the axes
float ringEcc(thread const Body& b, int k) { return sqrt(max(0.0, 1.0 - (b.ringB[k] * b.ringB[k]) / (b.ringA[k] * b.ringA[k]))); }

float2 ringLocal(thread const Body& b, float2 loc) {
  float cr = cos(b.rot), sr = sin(b.rot);
  return b.pos.xz + float2(loc.x * cr - loc.y * sr, loc.x * sr + loc.y * cr);
}

// a point on ring k by eccentric angle — for sampling the whole ellipse
float2 ringPoint(thread const Body& b, int k, float ang) {
  return ringLocal(b, float2(cos(ang) * b.ringA[k] - b.ringA[k] * ringEcc(b, k), sin(ang) * b.ringB[k]));
}

// where a satellite on ring k is at mean anomaly M: solve kepler's equation, then the true
// anomaly and radius measured from the focus, where the body is
float2 ringOrbit(thread const Body& b, int k, float M) {
  float e = ringEcc(b, k);
  float E = M + e * sin(M);
  for (int i = 0; i < 5; i++) E -= (E - e * sin(E) - M) / (1.0 - e * cos(E));
  float nu = 2.0 * atan2(sqrt(1.0 + e) * sin(0.5 * E), sqrt(1.0 - e) * cos(0.5 * E));
  float r = b.ringA[k] * (1.0 - e * e) / (1.0 + e * cos(nu));
  return ringLocal(b, r * float2(cos(nu), sin(nu)));
}

// mean motion on ring k: G·M = 0.35·mass in the sheet's units, as in the potential
float ringRate(thread const Body& b, int k) { return sqrt(0.35 * b.mass / (b.ringA[k] * b.ringA[k] * b.ringA[k])); }

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

// a 5x7 pixel font with just enough glyphs for "L1".."L5": rows top to bottom, bit 4 is the left column
constant int WP_FONT[6][7] = {
  {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F},   // L
  {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E},   // 1
  {0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F},   // 2
  {0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E},   // 3
  {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02},   // 4
  {0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E},   // 5
};

float glyphPx(int g, int2 c) {
  if (c.x < 0 || c.x > 4 || c.y < 0 || c.y > 6) return 0.0;
  return float((WP_FONT[g][c.y] >> (4 - c.x)) & 1);
}

// how much of a line-type mark survives at distance t: the sheet's fog, and then gone entirely
// past a couple of camera distances — a grazing camera sees the far wall of its own bowl with
// every contour stacked at the horizon, and those should dissolve, not stripe it
float markFade(float t, float fogRate, float dist) {
  return exp(-t * fogRate) * (1.0 - smoothstep(1.2, 2.4, t / dist));
}

// a dashed string from a to b — straight where it can be, draped over the sheet where the
// straight line would cut through a ridge. folds its best coverage into dash / dashFog
void dashedString(float3 ro, float3 rd, float3 a, float3 b, float tLimit, float pxPerUnit, float fogRate, float camDist,
                  thread const Body* bodies, int n, thread const Sat* sats, int ns, Frame fr,
                  thread float& dash, thread float& dashFog) {
  float s, uu;
  if (raySegment(ro, rd, a, b, s, uu) > 2.0) return;   // the drape lifts it, but not that far
  float len = length(b.xz - a.xz);
  const int K = 24;
  float3 prev = a;
  for (int k = 1; k <= K; k++) {
    float3 c = mix(a, b, float(k) / float(K));
    c.y = max(c.y, potential(c.xz, bodies, n, sats, ns, fr) + 0.025);
    float d = raySegment(ro, rd, prev, c, s, uu);
    float along = (float(k - 1) + uu) / float(K);
    prev = c;
    if (s > tLimit) continue;
    float lw = s / pxPerUnit * 1.3 * (WP_PARAM_ink > 0.5 ? 2.0 : 1.0);
    float on = step(fract(along * len / 0.22), 0.55);
    float cov = (1.0 - smoothstep(0.4 * lw, 1.4 * lw, d)) * on;
    if (cov > dash) { dash = cov; dashFog = markFade(s, fogRate, camDist); }
  }
}

// everything both passes need to agree on: the bodies, the frame, the lagrange points, the camera.
// built from the seed alone, so wp_post can rebuild it without a side channel
// scalars only: bodies, satellites, lagrange points and critical heights are written into
// caller-owned arrays. (a version that carried the arrays inside the struct and returned it by
// value came back with corrupted bodies and per-pixel-inconsistent lagrange points — pointers
// into a large struct local in a metal fragment function are not to be trusted)
struct Scene {
  int n, ns;
  Frame fr;
  bool three, graze, close;
  Palette pal;
  float3 center, ro, fwd, right, up;
  float aspect, tanHalf, dist, pxPerUnit, fogRate, dof, focus;
};

Scene buildScene(float S, float2 res, float time, thread Body* bodies, thread Sat* sats, thread float2* lag, thread float* critH) {
  Scene sc = {};
  float clock = time * WP_PARAM_speed;   // every orbit's time, in the sheet's units
  for (int i = 0; i < 5; i++) lag[i] = 0.0;
  for (int i = 0; i < 3; i++) critH[i] = 0.0;
  float aspect = res.x / res.y;
  float r0 = hash11(S), r1 = hash11(S + 1.0), r2 = hash11(S + 2.0), r3 = hash11(S + 3.0);

  Palette pal = palette(int(hash11(S + 4.0) * 5.0) % 5);

  // bodies: a loose cluster, one of them often dominant
  int n = 3 + int(hash11(S + 5.0) * 5.0);
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
  int ns = 0;
  for (int i = 0; i < n; i++) {
    for (int q = 0; q < bodies[i].rings; q++) {
      float kq = S + float(i) * 13.7 + float(q) * 3.1;
      float c = hash11(kq);
      int count = c < 0.35 ? 0 : (c < 0.65 ? 1 : (c < 0.88 ? 2 : 3));
      for (int s = 0; s < count && ns < MAX_SATS; s++) {
        float ks = kq + float(s) * 1.7 + 0.5;
        // a kepler orbit on this ring: starting phase by seed, advancing at the ring's mean motion
        float2 xz = ringOrbit(bodies[i], q, hash11(ks) * 6.2831853 + ringRate(bodies[i], q) * clock);
        sats[ns].pos = float3(xz.x, 0.0, xz.y);
        sats[ns].radius = (0.016 + hash11(ks + 1.0) * 0.02) * (WP_PARAM_ink > 0.5 ? 1.8 : 1.0);   // dots you can see in print
        // in print they're massless: a moving dimple shifts the whole sheet by a hair, and on a
        // 1-bit panel that re-decides dithered pixels everywhere — a moving dot changes a few rows
        sats[ns].mass = WP_PARAM_ink > 0.5 ? 0.0 : 0.006 + hash11(ks + 2.0) * 0.014;
        sats[ns].soft = sats[ns].radius * 8.0;
        sats[ns].parent = i;
        sats[ns].ring = q;
        ns++;
      }
    }
  }

  // two-body scene: a primary and secondary in circular orbit, drawn in their co-rotating frame.
  // the sheet is then the effective potential, so the lagrange points are its actual saddles
  // (L1–L3) and hilltops (L4, L5) — no approximations, found on the softened surface itself.
  // the only satellites are trojans: massless, librating about L4 and L5
  bool three = WP_PARAM_three >= 0.0 ? WP_PARAM_three > 0.5 : hash11(S + 13.0) < 0.3;
  Frame fr;
  fr.bary = 0.0; fr.w2 = 0.0; fr.phi0 = 0.0;
  if (three) {
    n = 2;
    ns = 0;
    float mu = 0.02 + pow(hash11(S + 14.0), 1.5) * 0.38;   // the secondary's share of the mass
    float R = 2.6 + hash11(S + 15.0);
    float m1 = 1.7 + hash11(S + 17.0) * 0.6, m2 = m1 * mu / (1.0 - mu);
    fr.w2 = 0.35 * (m1 + m2) / (R * R * R);   // ω² = G(M1+M2)/R³, with G·M = 0.35·mass in the sheet's units
    // the pair goes round the barycentre at ω; the co-rotating sheet, its lagrange points and the
    // trojans all turn with it
    float ang = hash11(S + 16.0) * 6.2831853 + sqrt(fr.w2) * clock;
    float2 dir = float2(cos(ang), sin(ang)), perp = float2(-dir.y, dir.x);
    float2 P = -dir * R * mu, Q = dir * R * (1.0 - mu);   // barycentre at the origin
    bodies[0].mass = m1; bodies[1].mass = m2;
    bodies[0].pos = float3(P.x, 0.0, P.y); bodies[1].pos = float3(Q.x, 0.0, Q.y);
    for (int i = 0; i < 2; i++) {
      bodies[i].radius = 0.06 + bodies[i].mass * 0.045;
      bodies[i].soft = bodies[i].radius * 5.5;
      bodies[i].core = pal.coreWhite;
      bodies[i].rings = 0;
      bodies[i].rot = 0.0;
    }
    center = 0.0;
    // L4, L5: start at the equilateral points and walk uphill onto the softened surface's true tops
    for (int k = 0; k < 2; k++) {
      float2 L = P + (dir * 0.5 + perp * (k == 0 ? 0.8660254 : -0.8660254)) * R;
      float step = 0.1 * R;
      for (int it = 0; it < 14; it++) {
        float best = potential(L, bodies, n, sats, ns, fr);
        float2 up = L;
        for (int d = 0; d < 4; d++) {
          float2 c = L + (d < 2 ? dir : perp) * (d % 2 == 0 ? step : -step);
          float v = potential(c, bodies, n, sats, ns, fr);
          if (v > best) { best = v; up = c; }
        }
        if (all(up == L)) step *= 0.5;
        L = up;
      }
      lag[3 + k] = L;
    }
    fr.phi0 = potential(lag[3], bodies, n, sats, ns, fr);   // hilltops become height 0, the sheet's ceiling
    // L1, L2, L3: where the slope along the axis crosses zero — between the bodies, beyond the
    // secondary, beyond the primary. the height rises then falls across each interval
    for (int k = 0; k < 3; k++) {
      float lo, hi;
      if (k == 0)      { lo = -R * mu + 0.06 * R;        hi = R * (1.0 - mu) - 0.06 * R; }
      else if (k == 1) { lo = R * (1.0 - mu) + 0.06 * R; hi = R * (1.0 - mu) + 1.5 * R; }
      else             { lo = -R * mu - 1.5 * R;         hi = -R * mu - 0.06 * R; }
      for (int it = 0; it < 40; it++) {
        float mid = 0.5 * (lo + hi);
        if (dot(gradient(dir * mid, bodies, n, sats, ns, fr), dir) > 0.0) lo = mid; else hi = mid;
      }
      lag[k] = dir * 0.5 * (lo + hi);
      critH[k] = potential(lag[k], bodies, n, sats, ns, fr);
    }
    // trojans: up to two test masses librating about each of L4 and L5 — tadpole orbits from the
    // linearised motion, long along the orbit and narrow across it, at the long-period frequency
    float wl = sqrt(fr.w2) * sqrt(max(0.0, 0.5 * (1.0 - sqrt(max(0.0, 1.0 - 27.0 * mu * (1.0 - mu))))));
    for (int k = 0; k < 2; k++) {
      int count = int(hash11(S + 18.0 + float(k)) * 3.0);
      float2 tang = normalize(float2(-lag[3 + k].y, lag[3 + k].x));
      for (int s = 0; s < count && ns < MAX_SATS; s++) {
        float ks = S + 19.0 + float(k) * 7.0 + float(s) * 1.3;
        float amp = (0.12 + hash11(ks) * 0.18) * R;
        float ph = hash11(ks + 1.0) * 6.2831853 + wl * clock;
        float2 xz = lag[3 + k] + tang * amp * sin(ph) + normalize(lag[3 + k]) * amp * 0.3 * cos(ph);
        sats[ns].pos = float3(xz.x, 0.0, xz.y);
        sats[ns].radius = 0.014 + hash11(ks + 2.0) * 0.016;
        sats[ns].mass = 0.0;
        sats[ns].soft = 1.0;
        sats[ns].parent = 1;
        sats[ns].ring = -1;
        ns++;
      }
    }
  }

  // bodies settle just above the floor of their own bowl; each ring floats just above the highest
  // point of the sheet beneath it, so it rests in the bowl and never sinks into a neighbour's wall
  for (int i = 0; i < n; i++) {
    bodies[i].pos.y = potential(bodies[i].pos.xz, bodies, n, sats, ns, fr) + bodies[i].radius * 0.9;
    for (int q = 0; q < bodies[i].rings; q++) {
      float top = -1e9;
      for (int a = 0; a < 16; a++) {
        top = max(top, potential(ringPoint(bodies[i], q, float(a) * 0.39269908), bodies, n, sats, ns, fr));
      }
      bodies[i].ringY[q] = top + 0.03;
    }
  }
  // satellites sit on their ring's plane; trojans sit on the sheet
  for (int i = 0; i < ns; i++) {
    sats[i].pos.y = (sats[i].ring < 0 ? potential(sats[i].pos.xz, bodies, n, sats, ns, fr) : bodies[sats[i].parent].ringY[sats[i].ring]) + sats[i].radius;
  }

  // camera: far and high over the cluster, close and medium, or grazing — down at the sheet
  // with bodies clipping the horizon
  // the two-body sheet is a dome that falls away past the pair, so no grazing shots there — the
  // camera would be standing on the rim looking in
  bool graze = r1 < 0.25 && !three, close = r1 < 0.55;
  float dist = WP_PARAM_dist >= 0.0 ? WP_PARAM_dist : (graze ? 2.6 + r2 * 2.0 : close ? 3.2 + r2 * 2.5 : 7.5 + r2 * 6.0);
  // (and its close shots stay high enough that the line of sight over a saddle lands on the dome,
  // not on the sky behind it)
  float el = WP_PARAM_el >= 0.0 ? WP_PARAM_el : (graze ? 0.07 + r3 * 0.13 : (close ? (three ? 0.36 : 0.22) : 0.42) + r3 * 0.36);
  // in print the camera drifts faster: at a panel's frame rate the satellites alone read as still
  float spin = WP_PARAM_spin >= 0.0 ? WP_PARAM_spin : (WP_PARAM_ink > 0.5 ? 0.05 : 0.02);
  float az = (WP_PARAM_az >= 0.0 ? WP_PARAM_az : hash11(S + 6.0) * 6.2831853) + spin * time;
  float3 target = center + float3(hash11(S + 7.0) - 0.5, 0.0, hash11(S + 8.0) - 0.5) * (close ? 2.5 : 1.0);
  target.y = graze ? -0.3 : (close ? -0.4 : -0.2);
  float3 ro = target + dist * float3(cos(el) * sin(az), sin(el), cos(el) * cos(az));
  float3 fwd = normalize(target - ro);
  float3 right = normalize(cross(fwd, float3(0, 1, 0)));
  float3 up = cross(right, fwd);
  float fov = close ? 0.62 : 0.55;
  float tanHalf = tan(fov * 0.5);
  float pxPerUnit = res.y / (2.0 * tanHalf);   // world -> pixels at distance 1
  // fog in proportion to the shot: a grazing camera a few units out wants the distance gone
  // much sooner than a high one, or far bowls' hot floors show through edge-on as pale streaks
  float fogRate = max(0.055, 0.4 / dist) * (WP_PARAM_ink > 0.5 ? 0.3 : 1.0);   // a print keeps its far lines
  // depth of field, strongest on the grazing shots where it reads as macro
  float rd0 = hash11(S + 20.0);
  float dof = WP_PARAM_dof >= 0.0 ? WP_PARAM_dof : (WP_PARAM_ink > 0.5 ? 0.0 : (graze ? 0.7 + rd0 * 0.3 : (close ? 0.3 + rd0 * 0.4 : 0.15 + rd0 * 0.3)));
  // focus on the subject: the body that looks biggest on screen, preferring one that is actually
  // in the frame — not the camera's target point, and not whichever small body sits nearest the
  // centre while the real subject is off to one side
  float focus = dist, bestSize = -1.0;
  for (int i = 0; i < n; i++) {
    float3 v = bodies[i].pos - ro;
    float z = dot(v, fwd);
    if (z <= 0.1) continue;
    float2 sp = float2(dot(v, right), dot(v, up)) / (z * tanHalf) / float2(aspect, 1.0);
    float size = bodies[i].radius / z * (all(abs(sp) < 1.0) ? 1.0 : 0.2);
    if (size > bestSize) { bestSize = size; focus = length(v); }
  }
  sc.focus = focus;

  sc.n = n; sc.ns = ns; sc.fr = fr;
  sc.three = three; sc.graze = graze; sc.close = close;
  sc.pal = pal;
  sc.center = center; sc.ro = ro; sc.fwd = fwd; sc.right = right; sc.up = up;
  sc.aspect = aspect; sc.tanHalf = tanHalf; sc.dist = dist; sc.pxPerUnit = pxPerUnit; sc.fogRate = fogRate; sc.dof = dof;
  return sc;
}

// the render code below reads the scene through these names (the arrays are the caller's)
#define UNPACK_SCENE(sc) \
  int n = sc.n, ns = sc.ns; Frame fr = sc.fr; \
  bool three = sc.three, graze = sc.graze, ink = WP_PARAM_ink > 0.5; \
  Palette pal = sc.pal; float3 center = sc.center, ro = sc.ro, fwd = sc.fwd, right = sc.right, up = sc.up; \
  float aspect = sc.aspect, tanHalf = sc.tanHalf, dist = sc.dist, pxPerUnit = sc.pxPerUnit, fogRate = sc.fogRate; \
  float camDist = dist;   /* the orbit loop shadows `dist` */

float4 wp_main(float2 uv, constant Uniforms& u) {
  float S = u.seed;
  Body bodies[MAX_BODIES];
  Sat sats[MAX_SATS];
  float2 lag[5];
  float critH[3];
  Scene sc = buildScene(S, u.res, u.time, bodies, sats, lag, critH);
  UNPACK_SCENE(sc)
  float2 p = (uv - 0.5) * 2.0 * float2(aspect, 1.0) * tanHalf;
  float3 rd = normalize(fwd + right * p.x + up * p.y);

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
      // in print: a white disc with a bold black rim (on black paper, just the disc)
      sphereCol = ink ? float3(WP_PARAM_ink > 1.5 ? 1.0 : 1.0 - smoothstep(0.3, 0.55, rim)) : mix(bodies[i].core * 1.6, pal.hot * 2.0, rim * 0.7);
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
      sphereCol = ink ? float3(WP_PARAM_ink > 1.5 ? 1.0 : 0.0) : mix(float3(0.55, 0.55, 0.6), pal.hot, 0.3) * lit * 1.2;   // print: a dot
    }
  }

  // raymarch the sheet. the potential is never above 0, so a rising ray above it can't hit
  float t = 0.0, tPrev = 0.0;
  bool hit = false;
  for (int i = 0; i < 240; i++) {
    float3 q = ro + rd * t;
    if (q.y > 0.04 && rd.y > 0.0) break;
    float dh = q.y - potential(q.xz, bodies, n, sats, ns, fr);
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
      if (q.y - potential(q.xz, bodies, n, sats, ns, fr) < 0.0) hi = mid; else lo = mid;
    }
    t = 0.5 * (lo + hi);
  }

  // the sky is exactly the flat sheet's colour and the sheet fogs into it, so the sheet reads
  // as going on forever rather than ending at a horizon
  float3 sunDir = normalize(float3(0.3, 1.0, 0.25));
  float3 sky = ink ? pal.bg : pal.bg * (0.5 + 0.5 * sunDir.y);   // print: the paper, whichever colour it is
  float3 col = sky;
  bool sphereFront = tS < t || (!hit && tS < 1e8);
  float tLimit = sphereFront ? tS : (hit ? t : 1e9);
  if (hit) {
    float3 q = ro + rd * t;
    float h = potential(q.xz, bodies, n, sats, ns, fr);
    float2 g = gradient(q.xz, bodies, n, sats, ns, fr);
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
      if (sats[i].mass <= 0.0) continue;   // trojans are test masses: no dimple, no glow
      float2 d = q.xz - sats[i].pos.xz;
      float w = sats[i].soft / sqrt(dot(d, d) + sats[i].soft * sats[i].soft) * 0.6;
      depth += w * w * w * w;
    }
    depth = pow(depth, 0.25);
    float lambert = max(0.0, dot(nrm, sunDir));
    col = ink ? pal.bg : pal.bg * (0.5 + 0.5 * lambert);   // paper isn't lit
    col = mix(col, pal.warm, smoothstep(0.25, 0.6, depth));
    col = mix(col, pal.hot, smoothstep(0.6, 1.0, depth) * 0.85);

    // isolines of the potential, constant width in screen pixels, brightening with depth
    float levels = 16.0;
    float f = h * levels;
    float fw = levels * length(g) * pixelWorld / facing + 1e-5;
    float dl = min(fract(f), 1.0 - fract(f));
    float wide = ink ? 2.5 : 1.0;   // a 1 px line doesn't survive 1 bit
    float line = 1.0 - smoothstep(0.3 * fw * wide, 1.2 * fw * wide, dl);
    float crowd = 1.0 - smoothstep(0.28, 0.55, fw);
    // contours brighten down the bowl, then go dark on the hot floor so they stay legible
    float3 lineCol = mix(pal.line, pal.lineHot, smoothstep(0.2, 0.6, depth));
    lineCol = mix(lineCol, pal.warm * 0.7, smoothstep(0.7, 1.0, depth));

    // optional disc edge: the sheet fades to nothing past a radius. not on grazing shots, where
    // the void past the rim would sit under a sheet-coloured sky
    float edge = 1.0;
    if (!graze && hash11(S + 9.0) < 0.55) {
      float R = 5.0 + hash11(S + 10.0) * 4.0;
      edge = 1.0 - smoothstep(R - 1.8, R + 0.3, length(q.xz - center.xz));
    }
    float fog = exp(-t * fogRate);
    float lineFog = markFade(t, fogRate, dist);

    float crit = 0.0;
    if (three) {
      // hill's zero-velocity curves: the contours at the L1, L2 and L3 energies — the roche lobes
      // meeting at L1, and the two envelopes outside — drawn brighter, with the ordinary contour
      // that would run beside each one suppressed so they don't read as doubled
      float hw = length(g) * pixelWorld / facing + 1e-6;
      for (int k = 0; k < 3; k++) {
        float dc = abs(h - critH[k]);
        crit = max(crit, 1.0 - smoothstep(0.7 * hw, 2.0 * hw, dc));
        line *= smoothstep(0.25 / levels, 0.5 / levels, dc);
      }
    }
    col = mix(col, lineCol, line * crowd * pal.lineAlpha * lineFog);
    col = mix(col, pal.lineHot, crit * 0.9 * lineFog);
    col = mix(ink ? sky : float3(0.0), col, edge);   // past the disc: the void, or in print, paper
    col = mix(col, sky, 1.0 - fog);
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
      loc.x += a * ringEcc(bodies[i], k);   // the body is at a focus; the ellipse's centre is back along the axis
      float dist = abs(length(loc / float2(a, b)) - 1.0) * min(a, b);
      float lw = tp / pxPerUnit * 1.3 / sqrt(max(abs(rd.y), 0.05)) * (ink ? 2.0 : 1.0);
      float cov = 1.0 - smoothstep(0.4 * lw, 1.4 * lw, dist);
      if (cov > orbit) { orbit = cov; orbitFog = markFade(tp, fogRate, camDist); }
    }
  }
  col = mix(col, pal.orbit, orbit * 0.9 * orbitFog);

  // dashed strings. the cluster's web links each body to its nearest earlier body; the two-body
  // scene draws its construction instead — the axis from L3 through both bodies to L2, and the
  // equilateral triangles that place L4 and L5
  float dash = 0.0, dashFog = 1.0;
  if (three) {
    float3 P3 = bodies[0].pos + float3(0, bodies[0].radius * 0.6, 0);
    float3 Q3 = bodies[1].pos + float3(0, bodies[1].radius * 0.6, 0);
    float3 L1 = float3(lag[0].x, critH[0] + 0.03, lag[0].y), L2 = float3(lag[1].x, critH[1] + 0.03, lag[1].y);
    float3 L3 = float3(lag[2].x, critH[2] + 0.03, lag[2].y);
    float3 L4 = float3(lag[3].x, 0.03, lag[3].y), L5 = float3(lag[4].x, 0.03, lag[4].y);
    dashedString(ro, rd, L3, P3, tLimit, pxPerUnit, fogRate, dist, bodies, n, sats, ns, fr, dash, dashFog);
    dashedString(ro, rd, P3, L1, tLimit, pxPerUnit, fogRate, dist, bodies, n, sats, ns, fr, dash, dashFog);
    dashedString(ro, rd, L1, Q3, tLimit, pxPerUnit, fogRate, dist, bodies, n, sats, ns, fr, dash, dashFog);
    dashedString(ro, rd, Q3, L2, tLimit, pxPerUnit, fogRate, dist, bodies, n, sats, ns, fr, dash, dashFog);
    dashedString(ro, rd, P3, L4, tLimit, pxPerUnit, fogRate, dist, bodies, n, sats, ns, fr, dash, dashFog);
    dashedString(ro, rd, Q3, L4, tLimit, pxPerUnit, fogRate, dist, bodies, n, sats, ns, fr, dash, dashFog);
    dashedString(ro, rd, P3, L5, tLimit, pxPerUnit, fogRate, dist, bodies, n, sats, ns, fr, dash, dashFog);
    dashedString(ro, rd, Q3, L5, tLimit, pxPerUnit, fogRate, dist, bodies, n, sats, ns, fr, dash, dashFog);
  } else {
    for (int i = 1; i < n; i++) {
      int j = 0;
      float best = 1e9;
      for (int k = 0; k < i; k++) {
        float dk = length(bodies[i].pos.xz - bodies[k].pos.xz);
        if (dk < best) { best = dk; j = k; }
      }
      float3 a = bodies[i].pos + float3(0, bodies[i].radius * 0.6, 0);
      float3 b = bodies[j].pos + float3(0, bodies[j].radius * 0.6, 0);
      dashedString(ro, rd, a, b, tLimit, pxPerUnit, fogRate, dist, bodies, n, sats, ns, fr, dash, dashFog);
    }
  }
  col = mix(col, pal.dash, dash * (three ? 0.6 : 0.85) * dashFog);

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
      if (q.y < potential(q.xz, bodies, n, sats, ns, fr)) { visible = false; break; }
    }
    if (!visible) continue;
    float tight = 1.0 / (1.0 + pow(dpx / max(rpx * 0.9, 2.0), 2.0));
    float wide = 1.0 / (1.0 + pow(dpx / max(rpx * 3.0, 6.0), 3.0));
    col += (bodies[i].core * tight * 0.35 + pal.hot * wide * 0.04 * bodies[i].mass) * fade;
  }

  // linear colour out, and the ray depth in alpha for the second pass. the sky is simply far
  float depth = sphereFront ? tS : (hit ? t : 400.0);
  return float4(col, depth);
}

// circle of confusion, in pixels, for a point at ray depth d: sharp within about a tenth of the
// focus distance either side of it, fully blurred beyond about half again as far or near
float cocRadius(float d, float focus, float maxCoc) {
  return maxCoc * clamp((abs(d - focus) - 0.12 * focus) / (0.6 * focus), 0.0, 1.0);
}

float4 wp_post(float2 uv, texture2d<float> scene, constant Uniforms& u) {
  float S = u.seed;
  Body bodies[MAX_BODIES];
  Sat sats[MAX_SATS];
  float2 lag[5];
  float critH[3];
  Scene sc = buildScene(S, u.res, u.time, bodies, sats, lag, critH);
  UNPACK_SCENE(sc)
  float2 px = uv * u.res;

  // depth of field as a gather over a per-pixel rotated spiral. each tap is an area sample — a
  // coarser mip level the farther out it sits, matching the gap between taps — so the disc fills
  // in smoothly rather than as speckle. a tap counts if its own circle of confusion reaches this
  // pixel and it isn't behind us, or if this pixel's own circle reaches the tap — so blurred
  // background never bleeds over a sharp foreground, while a blurred foreground does spill over
  // what's behind it
  float4 c0 = wp_scene(scene, uv);
  float focus = sc.focus;
  float maxCoc = u.res.y / 70.0 * sc.dof;
  float coc0 = cocRadius(c0.a, focus, maxCoc);
  float3 acc = c0.rgb;
  float wsum = 1.0;
  float rot = hash21(px + S) * 6.2831853;
  const int N = 64;
  for (int i = 0; i < N; i++) {
    float r = sqrt((float(i) + 0.5) / float(N));
    float a = float(i) * 2.39996323 + rot;
    float2 off = float2(cos(a), sin(a)) * r * maxCoc;
    float4 c = wp_scene(scene, uv + off / u.res, log2(max(1.0, 0.3 * length(off))));
    float cocT = cocRadius(c.a, focus, maxCoc) * step(c.a, c0.a * 1.05);
    float dpx = length(off);
    float w = smoothstep(dpx - 1.0, dpx + 1.0, max(coc0, cocT));
    acc += c.rgb * w;
    wsum += w;
  }
  float3 col = acc / wsum;

  // callouts: a ring on each lagrange point, a 45° leader, and its name in the pixel font —
  // screen-space UI, constant size, hidden where the sheet is in the way. drawn after the blur
  if (three) {
    float cell = max(3.0, round(u.res.y / 480.0));
    float ui = 0.0;
    for (int k = 0; k < 5; k++) {
      float3 wp = float3(lag[k].x, potential(lag[k], bodies, n, sats, ns, fr) + 0.02, lag[k].y);
      float3 v = wp - ro;
      float z = dot(v, fwd);
      if (z <= 0.1) continue;
      float2 sp = float2(dot(v, right), dot(v, up)) / (z * tanHalf);
      float2 m = (sp / float2(aspect, 1.0) * 0.5 + 0.5) * u.res;
      if (any(m < 0.0) || any(m > u.res)) continue;
      float2 d = px - m;
      if (dot(d, d) > 200.0 * 200.0) continue;
      float len = length(v);
      float3 dir = v / len;
      bool visible = true;
      for (int s = 1; s < 40; s++) {
        float tt = len * float(s) / 40.0;
        if (tt > len - 0.03) break;
        float3 q = ro + dir * tt;
        if (q.y < potential(q.xz, bodies, n, sats, ns, fr)) { visible = false; break; }
      }
      if (!visible) continue;
      float ring = 1.0 - smoothstep(0.8, 1.8, abs(length(d) - 5.0));
      float2 a = m + 3.5, b = m + 26.0;
      float2 ab = b - a;
      float along = clamp(dot(px - a, ab) / dot(ab, ab), 0.0, 1.0);
      float leader = 1.0 - smoothstep(0.6, 1.4, length(px - (a + ab * along)));
      float2 o = floor(b) + float2(4.0, -3.0);   // label's bottom-left, pixel aligned
      int2 c = int2(floor((px - o) / cell));      // c.y counts up from the baseline
      float text = 0.0;
      if (c.y >= 0 && c.y < 7) {
        int row = 6 - c.y;
        if (c.x >= 0 && c.x < 5) text = glyphPx(0, int2(c.x, row));
        else if (c.x >= 6 && c.x < 11) text = glyphPx(k + 1, int2(c.x - 6, row));
      }
      ui = max(ui, max(ring, max(leader, text)));
    }
    col = mix(col, pal.line * 1.5, ui * 0.9);
  }

  if (WP_PARAM_ink > 0.5) {
    col = clamp(col, 0.0, 1.0);   // paper stays paper: no vignette, no tonemap
  } else {
    col *= 1.0 - 0.3 * dot(uv - 0.5, uv - 0.5);
    col = col / (1.0 + col * 0.35);
  }
  col = pow(max(col, 0.0), float3(1.0 / 2.2));
  col += (hash21(uv * u.res + S) - 0.5) * 0.008;
  return float4(min(col, 1.0), 1.0);
}
