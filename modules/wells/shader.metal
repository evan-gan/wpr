// gravity wells, after mjmurdoc: a gravitational potential surface raymarched in perspective,
// isolines drawn on the surface, glowing bodies lighting their own wells, satellites,
// orbit ellipses, and a dashed web between the masses.

#define MAX_BODIES 7

struct Body {
  float3 pos;      // world position of the sphere center
  float mass;
  float radius;
  float soft;      // softening length of its well
  float3 core;     // emissive sphere color
  float3 glow;     // color it throws onto the well walls
  float orbitA, orbitB, orbitRot;   // ellipse drawn on the surface around it (0 = none)
  int satellites;
};

struct Palette {
  float3 bg, line, dash, orbit, coreWhite, glowA, glowB;
  float lineAlpha;
};

Palette palette(int i) {
  Palette p;
  p.lineAlpha = 0.85;
  switch (i) {
    case 0:  // ember on teal
      p.bg = float3(0.004, 0.016, 0.014); p.line = float3(0.80, 0.84, 0.78); p.dash = float3(0.90, 0.45, 0.40);
      p.orbit = float3(0.85, 0.70, 0.35); p.coreWhite = float3(1.0, 0.95, 0.85);
      p.glowA = float3(1.0, 0.45, 0.12); p.glowB = float3(1.0, 0.70, 0.30); break;
    case 1:  // ink: gray lines, red wells
      p.bg = float3(0.004, 0.004, 0.005); p.line = float3(0.45, 0.46, 0.48); p.dash = float3(0.85, 0.20, 0.18);
      p.orbit = float3(0.55, 0.55, 0.55); p.coreWhite = float3(1.0, 0.92, 0.92);
      p.glowA = float3(0.90, 0.12, 0.10); p.glowB = float3(1.0, 0.55, 0.30); p.lineAlpha = 0.7; break;
    case 2:  // neon: green contours, electric blue wells
      p.bg = float3(0.002, 0.005, 0.018); p.line = float3(0.15, 0.95, 0.45); p.dash = float3(0.25, 0.40, 0.95);
      p.orbit = float3(0.30, 0.80, 0.95); p.coreWhite = float3(0.92, 0.98, 1.0);
      p.glowA = float3(0.05, 0.35, 1.0); p.glowB = float3(0.20, 0.65, 1.0); p.lineAlpha = 0.9; break;
    case 3:  // gold on navy, salmon dashes
      p.bg = float3(0.010, 0.010, 0.024); p.line = float3(0.45, 0.50, 0.75); p.dash = float3(0.95, 0.40, 0.30);
      p.orbit = float3(0.90, 0.75, 0.40); p.coreWhite = float3(1.0, 0.96, 0.80);
      p.glowA = float3(1.0, 0.40, 0.15); p.glowB = float3(1.0, 0.65, 0.35); p.lineAlpha = 0.7; break;
    default: // magenta on violet, cyan orbits
      p.bg = float3(0.012, 0.003, 0.018); p.line = float3(0.55, 0.40, 0.75); p.dash = float3(0.30, 0.90, 0.95);
      p.orbit = float3(0.35, 0.95, 0.95); p.coreWhite = float3(1.0, 0.90, 1.0);
      p.glowA = float3(1.0, 0.15, 0.60); p.glowB = float3(0.95, 0.40, 0.90); p.lineAlpha = 0.75; break;
  }
  return p;
}

// the potential: softened 1/r wells, summed. always <= 0, flat far away
float potential(float2 xz, thread const Body* b, int n) {
  float h = 0.0;
  for (int i = 0; i < n; i++) {
    float2 d = xz - b[i].pos.xz;
    h -= b[i].mass * 0.35 / sqrt(dot(d, d) + b[i].soft * b[i].soft);
  }
  return h;
}

float2 gradient(float2 xz, thread const Body* b, int n) {
  float e = 0.006;
  return float2(potential(xz + float2(e, 0), b, n) - potential(xz - float2(e, 0), b, n),
                potential(xz + float2(0, e), b, n) - potential(xz - float2(0, e), b, n)) / (2.0 * e);
}

float sphereHit(float3 ro, float3 rd, float3 c, float r) {
  float3 oc = ro - c;
  float bq = dot(oc, rd);
  float cq = dot(oc, oc) - r * r;
  float disc = bq * bq - cq;
  if (disc < 0.0) return -1.0;
  float t = -bq - sqrt(disc);
  return t > 0.0 ? t : -1.0;
}

// distance from p to segment ab, and the parameter along it
float segDist(float2 p, float2 a, float2 b, thread float& u) {
  float2 ab = b - a;
  u = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
  return length(p - (a + ab * u));
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
    bodies[i].soft = bodies[i].radius * 2.6;
    bodies[i].pos = float3(xz.x, 0.0, xz.y);
    float warm = hash11(k + 4.0);
    bodies[i].core = pal.coreWhite;
    bodies[i].glow = mix(pal.glowA, pal.glowB, warm);
    bool hasOrbit = hash11(k + 5.0) < 0.6;
    bodies[i].orbitA = hasOrbit ? bodies[i].radius * (3.0 + hash11(k + 6.0) * 4.0) : 0.0;
    bodies[i].orbitB = bodies[i].orbitA * (0.55 + hash11(k + 7.0) * 0.45);
    bodies[i].orbitRot = hash11(k + 8.0) * 3.1416;
    bodies[i].satellites = int(hash11(k + 9.0) * 4.0);
    center += bodies[i].pos;
  }
  center /= float(n);
  // settle each body just above the bottom of its own well
  for (int i = 0; i < n; i++) {
    bodies[i].pos.y = potential(bodies[i].pos.xz, bodies, n) + bodies[i].radius * 0.9;
  }

  // camera: orbit the cluster, closer or farther by seed
  bool close = r1 < 0.4;
  float dist = close ? 3.2 + r2 * 2.5 : 7.5 + r2 * 6.0;
  float el = (close ? 0.30 : 0.36) + r3 * 0.36;
  float az = hash11(S + 6.0) * 6.2831853;
  float3 target = center + float3(hash11(S + 7.0) - 0.5, 0.0, hash11(S + 8.0) - 0.5) * (close ? 2.5 : 1.0);
  target.y = close ? -0.4 : -0.2;
  float3 ro = target + dist * float3(cos(el) * sin(az), sin(el), cos(el) * cos(az));
  float3 fwd = normalize(target - ro);
  float3 right = normalize(cross(fwd, float3(0, 1, 0)));
  float3 up = cross(right, fwd);
  float fov = close ? 0.62 : 0.55;
  float tanHalf = tan(fov * 0.5);
  float2 p = (uv - 0.5) * 2.0 * float2(aspect, 1.0) * tanHalf;
  float3 rd = normalize(fwd + right * p.x + up * p.y);

  // spheres first: bodies and their satellites
  float tS = 1e9;
  float3 sphereCol = 0.0;
  for (int i = 0; i < n; i++) {
    float t = sphereHit(ro, rd, bodies[i].pos, bodies[i].radius);
    if (t > 0.0 && t < tS) {
      tS = t;
      float3 nrm = normalize(ro + rd * t - bodies[i].pos);
      float rim = pow(1.0 - max(0.0, dot(nrm, -rd)), 2.0);
      sphereCol = mix(bodies[i].core * 1.6, bodies[i].glow * 2.2, rim * 0.7);
    }
    for (int s = 0; s < bodies[i].satellites; s++) {
      float ks = S + float(i) * 13.7 + float(s) * 3.1;
      float ang = hash11(ks) * 6.2831853;
      float orbA = bodies[i].orbitA > 0.0 ? bodies[i].orbitA : bodies[i].radius * 4.0;
      float orbB = bodies[i].orbitA > 0.0 ? bodies[i].orbitB : orbA * 0.8;
      float2 loc = float2(cos(ang) * orbA, sin(ang) * orbB);
      float cr = cos(bodies[i].orbitRot), sr = sin(bodies[i].orbitRot);
      float2 xz = bodies[i].pos.xz + float2(loc.x * cr - loc.y * sr, loc.x * sr + loc.y * cr);
      float sr2 = 0.018 + hash11(ks + 1.0) * 0.02;
      float3 sp = float3(xz.x, potential(xz, bodies, n) + sr2 * 1.2, xz.y);
      float t2 = sphereHit(ro, rd, sp, sr2);
      if (t2 > 0.0 && t2 < tS) {
        tS = t2;
        float3 nrm = normalize(ro + rd * t2 - sp);
        float lit = 0.35 + 0.65 * max(0.0, dot(nrm, normalize(bodies[i].pos - sp)));
        sphereCol = mix(float3(0.55, 0.55, 0.6), bodies[i].glow, 0.3) * lit * 1.2;
      }
    }
  }

  // raymarch the sheet. the potential is never above 0, so a rising ray above it can't hit
  float t = 0.0, tPrev = 0.0;
  bool hit = false;
  for (int i = 0; i < 240; i++) {
    float3 q = ro + rd * t;
    if (q.y > 0.04 && rd.y > 0.0) break;
    float dh = q.y - potential(q.xz, bodies, n);
    if (dh < 0.0015) { hit = true; break; }
    tPrev = t;
    t += clamp(dh * 0.45, 0.004, 0.5);
    if (t > tS || t > 70.0) break;
  }
  if (hit) {
    float lo = tPrev, hi = t;
    for (int i = 0; i < 6; i++) {
      float mid = 0.5 * (lo + hi);
      float3 q = ro + rd * mid;
      if (q.y - potential(q.xz, bodies, n) < 0.0) hi = mid; else lo = mid;
    }
    t = 0.5 * (lo + hi);
  }

  float3 col;
  if (tS < t || (!hit && tS < 1e8)) {
    col = sphereCol;
    t = tS;
  } else if (hit) {
    float3 q = ro + rd * t;
    float h = potential(q.xz, bodies, n);
    float2 g = gradient(q.xz, bodies, n);
    float3 nrm = normalize(float3(-g.x, 1.0, -g.y));
    float facing = max(0.25, abs(dot(nrm, -rd)));
    float pixelWorld = t * 2.0 * tanHalf / u.res.y;

    // the sheet itself: dark, lit faintly from above, and by each body's glow into its well
    float lambert = max(0.0, dot(nrm, normalize(float3(0.3, 1.0, 0.25))));
    col = pal.bg * (0.4 + 0.5 * lambert);
    // each body lights its own well and little else: tight falloff with a hard-ish cutoff
    for (int i = 0; i < n; i++) {
      float rr = length(q - bodies[i].pos);
      float glow = bodies[i].mass / (rr * rr * 28.0 + 0.10) * exp(-rr * 1.6);
      col += bodies[i].glow * min(glow * 0.035, 0.22);
    }

    // isolines of the potential, constant width in screen pixels
    float levels = 12.0;
    float f = h * levels;
    float fw = levels * length(g) * pixelWorld / facing + 1e-5;
    float dl = min(fract(f), 1.0 - fract(f));
    float line = 1.0 - smoothstep(0.3 * fw, 1.2 * fw, dl);
    float crowd = 1.0 - smoothstep(0.28, 0.55, fw);
    float lw = pixelWorld * 1.3 / facing;

    // orbit ellipses drawn on the surface
    float orbit = 0.0;
    for (int i = 0; i < n; i++) {
      if (bodies[i].orbitA <= 0.0) continue;
      float2 d = q.xz - bodies[i].pos.xz;
      float cr = cos(-bodies[i].orbitRot), sr = sin(-bodies[i].orbitRot);
      float2 loc = float2(d.x * cr - d.y * sr, d.x * sr + d.y * cr);
      for (int k = 0; k < 2; k++) {
        float a = bodies[i].orbitA * (1.0 + float(k) * 0.22), b = bodies[i].orbitB * (1.0 + float(k) * 0.18);
        float rr = length(loc / float2(a, b));
        float dist = abs(rr - 1.0) * min(a, b);
        orbit = max(orbit, 1.0 - smoothstep(0.4 * lw, 1.4 * lw, dist));
      }
    }

    // dashed web: each body links to an earlier one
    float dash = 0.0;
    for (int i = 1; i < n; i++) {
      int j = int(hash11(S + float(i) * 5.7) * float(i));
      float uu;
      float dist = segDist(q.xz, bodies[i].pos.xz, bodies[j].pos.xz, uu);
      float segLen = length(bodies[i].pos.xz - bodies[j].pos.xz);
      float on = step(fract(uu * segLen / 0.22), 0.55);
      dash = max(dash, (1.0 - smoothstep(0.4 * lw, 1.4 * lw, dist)) * on);
    }

    // optional disc edge: the sheet fades to nothing past a radius
    float edge = 1.0;
    if (hash11(S + 9.0) < 0.55) {
      float R = 5.0 + hash11(S + 10.0) * 4.0;
      edge = 1.0 - smoothstep(R - 1.8, R + 0.3, length(q.xz - center.xz));
    }
    float fog = exp(-t * 0.055);

    col = mix(col, pal.line, line * crowd * pal.lineAlpha * fog);
    col = mix(col, pal.orbit, orbit * 0.9 * fog);
    col = mix(col, pal.dash, dash * 0.85 * fog);
    col *= edge;
    col = mix(col, pal.bg * 0.35, 1.0 - fog);
  } else {
    col = pal.bg * 0.3;
  }

  // bloom: screen-space halos around every body, tight core plus a wide soft one
  for (int i = 0; i < n; i++) {
    float3 v = bodies[i].pos - ro;
    float z = dot(v, fwd);
    if (z <= 0.1) continue;
    float2 sp = float2(dot(v, right), dot(v, up)) / (z * tanHalf);
    float2 spx = (sp / float2(aspect, 1.0) * 0.5 + 0.5) * u.res;
    float dpx = length(uv * u.res - spx);
    float rpx = bodies[i].radius / (z * tanHalf) * u.res.y * 0.5;
    float tight = 1.0 / (1.0 + pow(dpx / max(rpx * 0.9, 2.0), 2.0));
    float wide = 1.0 / (1.0 + pow(dpx / max(rpx * 3.0, 6.0), 3.0));
    col += bodies[i].core * tight * 0.35 + bodies[i].glow * wide * 0.04 * bodies[i].mass;
  }

  col *= 1.0 - 0.3 * dot(uv - 0.5, uv - 0.5);
  col = col / (1.0 + col * 0.35);
  col = pow(max(col, 0.0), float3(1.0 / 2.2));
  col += (hash21(uv * u.res + S) - 0.5) * 0.008;
  return float4(min(col, 1.0), 1.0);
}
