// spectra: a light leak through glass, photographed on film. one to three lamps, each a soft
// shape drawn once per wavelength — every wavelength lands shifted along the glass's dispersion
// axis (blue further than red, 1/λ²) and a little blurrier than green (red and blue are out of
// focus when green isn't). the lamps add in linear light, wp_post convolves that with the lens's
// defocus disc — nothing in these photos is in focus, and a corner convolved with a disc is no
// longer a corner — and then a film curve clips the middle toward each lamp's colour and never
// lets the blacks reach black.
//
// measured from the references (sRGB): backgrounds (49,43,39) (27,22,25) (21,19,22) (16,11,8);
// clipped interiors (134,212,233) cyan, (211,196,225) lavender, (197,199,178) straw, (211,170,230)
// pink. across the cyan blob's dispersion axis the violet side runs ~200px, the red side ~100px.

// `--set shape=N` picks the hero shape (0 slab, 1 blob, 2 pill, 3 fan, 4 arch, 5 cone, 6 streak,
// 7 ring, 8 wedge, 9 crescent); negative = seeded
#ifndef WP_PARAM_shape
#define WP_PARAM_shape -1.0
#endif
// `--set disp=X` sets how far the spectrum spreads, as a fraction of the shape's size; negative = seeded
#ifndef WP_PARAM_disp
#define WP_PARAM_disp -1.0
#endif
// `--set tint=N` picks the hero's colour (0 cyan, 1 lavender, 2 straw, 3 pink, 4 peach, 5 blue-white); negative = seeded
#ifndef WP_PARAM_tint
#define WP_PARAM_tint -1.0
#endif
// `--set exposure=X` scales the light before the film curve; negative = seeded
#ifndef WP_PARAM_exposure
#define WP_PARAM_exposure -1.0
#endif

// --- spectrum -------------------------------------------------------------------------------

// piecewise-gaussian fit to the CIE 1931 colour matching functions (wyman, sloan, shirley 2013)
float cieG(float l, float mu, float s1, float s2) {
  float t = (l - mu) / (l < mu ? s1 : s2);
  return exp(-0.5 * t * t);
}
float3 cieXYZ(float l) {
  float x = 1.056 * cieG(l, 599.8, 37.9, 31.0) + 0.362 * cieG(l, 442.0, 16.0, 26.7) - 0.065 * cieG(l, 501.1, 20.4, 26.2);
  float y = 0.821 * cieG(l, 568.8, 46.9, 40.5) + 0.286 * cieG(l, 530.9, 16.3, 31.1);
  float z = 1.217 * cieG(l, 437.0, 11.8, 36.0) + 0.681 * cieG(l, 459.0, 26.0, 13.8);
  return float3(x, y, z);
}
float3 xyz2rgb(float3 c) {
  return float3( 3.2406 * c.x - 1.5372 * c.y - 0.4986 * c.z,
                -0.9689 * c.x + 1.8758 * c.y + 0.0415 * c.z,
                 0.0557 * c.x - 0.2040 * c.y + 1.0570 * c.z);
}

// the colour the film clips to: the interiors of the references, in linear light
//   0 cyan (134,212,233)  1 lavender (211,196,225)  2 straw (197,199,178)  3 pink (211,170,230)
//   4 peach (the orange lobe of 3457, toned down)    5 blue-white (132,176,219)
float3 clipTint(int i) {
  switch (i) {
    case 0:  return float3(0.24, 0.66, 0.82);
    case 1:  return float3(0.65, 0.55, 0.75);
    case 2:  return float3(0.56, 0.57, 0.45);
    case 3:  return float3(0.65, 0.40, 0.79);
    case 4:  return float3(0.80, 0.58, 0.50);
    default: return float3(0.23, 0.43, 0.70);
  }
}

// the source's spectrum: a tilt toward blue or red, and a dip in the green for the magenta leaks
float sourceWeight(float l, float tilt, float greenDip) {
  float w = 1.0 + tilt * (l - 550.0) / 150.0;
  float g = (l - 540.0) / 45.0;
  w *= 1.0 - greenDip * exp(-g * g);
  return max(w, 0.0);
}

// where wavelength l lands relative to green: glass disperses as 1/λ², so violet travels
// about twice as far as red. 400nm -> +0.89, 550nm -> 0, 700nm -> -0.38
float dispersion(float l) { return 550.0 * 550.0 / (l * l) - 1.0; }

// --- shapes -----------------------------------------------------------------------------------

float sdRoundBox(float2 p, float2 b, float r) {
  float2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
float sdEllipse(float2 p, float2 ab) {
  // good enough for a blurred blob: scaled circle, corrected by the smaller axis
  return (length(p / ab) - 1.0) * min(ab.x, ab.y);
}
// an exact trapezoid (iq): half-widths r1 at the bottom and r2 at the top, half-height he. it
// has to be a real distance — the fan used to be a box in a space squeezed by y, and a distance
// measured there grows faster along the sides than the ends, so the blur changed width along a
// line across the shape and left a seam
float sdTrapezoid(float2 p, float r1, float r2, float he) {
  float2 k1 = float2(r2, he);
  float2 k2 = float2(r2 - r1, 2.0 * he);
  p.x = abs(p.x);
  float2 ca = float2(p.x - min(p.x, (p.y < 0.0) ? r1 : r2), abs(p.y) - he);
  float2 cb = p - k1 + k2 * clamp(dot(k1 - p, k2) / dot(k2, k2), 0.0, 1.0);
  float s = (cb.x < 0.0 && ca.y < 0.0) ? -1.0 : 1.0;
  return s * sqrt(min(dot(ca, ca), dot(cb, cb)));
}
float sdSegment(float2 p, float2 a, float2 b) {
  float2 pa = p - a, ba = b - a;
  float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h);
}

// the shapes a leak can take. the first five are the references; the rest are what the same
// glass does to other lamps
#define SH_SLAB     0   // a wide rounded bar, the cyan reference
#define SH_BLOB     1   // an ellipse
#define SH_PILL     2   // tall, standing: a tombstone
#define SH_FAN      3   // widens toward one end and runs off the frame
#define SH_ARCH     4   // a thick "n"
#define SH_CONE     5   // narrow top, wide foot, heavily rounded: a lamp shade
#define SH_STREAK   6   // a long thin bar: light through a slit
#define SH_RING     7   // a hollow ellipse: light round a glass rim
#define SH_WEDGE    8   // a rounded triangle
#define SH_CRESCENT 9   // a blob with another blob bitten out of it
#define SH_COUNT    10

struct Shape {
  int kind;
  float2 center;
  float2 size;    // half extents
  float rot;
  float round;
  float wobble;   // low-frequency bend of the outline, so nothing is a perfect primitive
  float barrel;   // lens distortion of the shape's frame: straight edges bow
  bool cut;       // sliced by a straight edge — the shadow of something between lamp and glass
  float2 cutN;    // the edge's normal (in the shape's frame) and offset from its centre
  float cutOff;
};

float2 rot2(float2 p, float a) {
  float c = cos(a), s = sin(a);
  return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// signed distance to the shape, in frame units (frame height = 1)
float shapeSD(Shape sh, float2 p, float S) {
  float2 q = rot2(p - sh.center, -sh.rot);
  // a slow bend: the glass wasn't flat and the source wasn't a perfect rectangle. the seed goes
  // through a hash into a small offset — added raw, a seed in the millions eats the fractional
  // part of the coordinate (float32 spacing is 1.0 up there) and the noise turns into steps
  q *= 1.0 + sh.barrel * dot(q, q);
  float2 so = float2(hash11(S + 40.0), hash11(S + 41.0)) * 100.0;
  q += (float2(vnoise(q * 1.1 + so), vnoise(q * 1.1 + so + 31.0)) - 0.5) * sh.wobble;
  float d;
  switch (sh.kind) {
    case SH_SLAB:   d = sdRoundBox(q, sh.size, sh.round); break;
    case SH_BLOB:   d = sdEllipse(q, sh.size); break;
    case SH_PILL:   d = sdRoundBox(q, sh.size, min(sh.size.x, sh.size.y) * sh.round); break;
    // rounding is `distance - r`, which grows the shape by r on every side, so the trapezoids are
    // inset by r first: the rounded shape keeps the outline the size was chosen for
    case SH_FAN:    d = sdTrapezoid(q, max(sh.size.x * 0.3 - sh.round, 0.01), sh.size.x * 1.7 - sh.round, sh.size.y * 1.8 - sh.round) - sh.round; break;
    case SH_ARCH: {
      float2 a = float2(-sh.size.x, -sh.size.y), b = float2(-sh.size.x, sh.size.y);
      float2 c = float2(sh.size.x, sh.size.y), e = float2(sh.size.x, -sh.size.y * 0.2);
      d = min(sdSegment(q, a, b), min(sdSegment(q, b, c), sdSegment(q, c, e))) - sh.round;
      break;
    }
    case SH_CONE:   d = sdTrapezoid(q, sh.size.x - sh.round, max(sh.size.x * 0.45 - sh.round, 0.01), sh.size.y - sh.round) - sh.round; break;
    case SH_STREAK: d = sdRoundBox(q, sh.size, sh.size.y); break;
    case SH_RING:   d = abs(sdEllipse(q, sh.size) + sh.round) - sh.round; break;
    case SH_WEDGE:  d = sdTrapezoid(q, sh.size.x - sh.round, 0.01, sh.size.y - sh.round) - sh.round; break;
    default: {      // crescent: the bite is a second ellipse shifted toward one side
      float2 bite = q - float2(sh.size.x * 0.55, sh.size.y * 0.15);
      d = max(sdEllipse(q, sh.size), -sdEllipse(bite, sh.size * float2(0.85, 0.95)));
    }
  }
  if (sh.cut) d = max(d, dot(q, sh.cutN) - sh.cutOff);
  return d;
}

// coverage of a defocused edge: the shape blurred by a disc of radius `blur`
float coverage(float d, float blur) {
  return 1.0 - smoothstep(-blur, blur, d);
}

// --- scene ------------------------------------------------------------------------------------

#define MAX_LEAKS 3

// one lamp seen through the glass: a shape, its colour, how bright, and how much of the glass's
// dispersion it gets (a lamp nearer the glass spreads less)
struct Leak {
  Shape sh;
  float3 tint;
  float exposure;
  float dispScale;
  float blurScale;
  float2 grad;      // which way the lamp gets brighter
};

struct Scene {
  int n;
  float2 axis;      // dispersion direction — one piece of glass, so shared
  float disp;       // how far 550->400nm travels, frame units, for dispScale = 1
  float blur;       // per-wavelength softness of the green image
  float defocus;    // the lens's defocus disc, applied to the summed light in wp_post
  float caBlur;     // how much blurrier the ends of the spectrum are
  float tilt, greenDip;
  float3 base;      // the film's black
  bool reflect;
  float floorY;     // the floor the first leak reflects in, if it does
};

Shape makeShape(int kind, float S, float aspect) {
  Shape sh;
  sh.kind = kind;
  float r1 = hash11(S + 1.0), r2 = hash11(S + 2.0), r3 = hash11(S + 3.0), r4 = hash11(S + 4.0), r5 = hash11(S + 5.0), r6 = hash11(S + 6.0);
  // off-centre, sometimes cropped by the frame — the references never centre the light
  sh.center = float2((r1 - 0.5) * aspect * 0.7, (r2 - 0.5) * 0.6);
  sh.rot = (r3 - 0.5) * 0.5;
  sh.wobble = 0.03 + r4 * 0.05;   // and a slow bend on top: the glass isn't flat
  sh.barrel = (hash11(S + 45.0) - 0.4) * 1.6;
  sh.round = 0.0;
  switch (kind) {
    case SH_SLAB:     sh.size = float2(0.28 + r4 * 0.25, 0.09 + r5 * 0.08); sh.round = sh.size.y * 0.9; break;
    case SH_BLOB:     sh.size = float2(0.22 + r4 * 0.2, 0.18 + r5 * 0.2); break;
    case SH_PILL:     sh.size = float2(0.12 + r4 * 0.1, 0.24 + r5 * 0.14); sh.round = 0.7 + r6 * 0.3; sh.rot *= 0.4; break;
    case SH_FAN:      sh.size = float2(0.16 + r4 * 0.12, 0.3); sh.round = sh.size.x * (0.4 + r6 * 0.4); sh.rot = (r3 - 0.5) * 1.2; sh.center.y -= 0.25; break;
    case SH_ARCH:     sh.size = float2(0.18 + r4 * 0.12, 0.16 + r5 * 0.12); sh.round = 0.10 + r6 * 0.06; sh.wobble *= 0.3; break;
    case SH_CONE:     sh.size = float2(0.14 + r4 * 0.1, 0.22 + r5 * 0.14); sh.round = sh.size.x * (0.45 + r6 * 0.4); sh.rot *= 0.5; break;
    case SH_STREAK:   sh.size = float2(0.35 + r4 * 0.4, 0.02 + r5 * 0.035); sh.rot = (r3 - 0.5) * 2.4; break;
    case SH_RING:     sh.size = float2(0.22 + r4 * 0.15, 0.18 + r5 * 0.15); sh.round = min(sh.size.x, sh.size.y) * (0.4 + r6 * 0.3); break;   // a fat wall, a small soft hole
    case SH_WEDGE:    sh.size = float2(0.2 + r4 * 0.15, 0.22 + r5 * 0.15); sh.round = min(sh.size.x, sh.size.y) * (0.35 + r6 * 0.35); sh.rot = (r3 - 0.5) * 3.0; break;
    default:          sh.size = float2(0.2 + r4 * 0.15, 0.22 + r5 * 0.15); sh.rot = (r3 - 0.5) * 3.0; break;
  }
  // sometimes the light is close and fills half the frame, cropped by its edge
  float scale = 0.8 + hash11(S + 24.0) * 0.8;
  if (hash11(S + 25.0) < 0.25) scale *= 1.7;
  sh.size *= scale; sh.round *= scale;
  // something between the lamp and the glass throws a straight shadow across it
  sh.cut = hash11(S + 27.0) < 0.25 && kind != SH_STREAK && kind != SH_RING;
  float ca = hash11(S + 28.0) * 6.2831853;
  sh.cutN = float2(cos(ca), sin(ca));
  sh.cutOff = (hash11(S + 29.0) - 0.3) * max(sh.size.x, sh.size.y) * 0.8;
  return sh;
}

Scene buildScene(float S, float aspect, thread Leak* leaks) {
  Scene sc;

  // the glass edge is usually upright and the camera level, so the spectrum mostly runs
  // sideways — either way — and now and then at any angle
  float ang = hash11(S + 8.0) < 0.7 ? (hash11(S + 9.0) - 0.5) * 1.4 : hash11(S + 7.0) * 6.2831853;
  sc.axis = float2(cos(ang), sin(ang));
  sc.blur = 0.035 + hash11(S + 11.0) * 0.045;
  // the lens's defocus disc, frame units. it has to stay narrower than the dispersion fringes:
  // a fringe blurred wider than it is turns pastel, and the references' fringes are saturated
  sc.defocus = 0.015 + hash11(S + 43.0) * 0.025;
  sc.caBlur = 0.3 + hash11(S + 12.0) * 0.7;
  sc.tilt = (hash11(S + 14.0) - 0.5) * 0.6;
  sc.greenDip = hash11(S + 15.0) < 0.35 ? 0.5 : 0.0;

  // the film base: never black, usually warm, once in a while cool
  float lift = 0.004 + hash11(S + 18.0) * 0.02;   // (16..45)/255 after gamma, as measured
  sc.base = hash11(S + 17.0) < 0.75 ? float3(1.0, 0.88, 0.8) * lift : float3(0.75, 0.72, 1.0) * lift;

  // the hero
  int kind = WP_PARAM_shape >= 0.0 ? int(WP_PARAM_shape) : int(hash11(S) * float(SH_COUNT)) % SH_COUNT;
  leaks[0].sh = makeShape(kind, S, aspect);
  int tint = WP_PARAM_tint >= 0.0 ? int(WP_PARAM_tint) : int(hash11(S + 13.0) * 6.0) % 6;
  leaks[0].tint = clipTint(tint);
  leaks[0].exposure = WP_PARAM_exposure >= 0.0 ? WP_PARAM_exposure : 1.2 + hash11(S + 16.0) * 1.6;
  leaks[0].dispScale = 1.0;
  leaks[0].blurScale = 1.0;
  float ga = hash11(S + 26.0) * 6.2831853;
  leaks[0].grad = float2(cos(ga), sin(ga));
  // the spread is sized to the shape's thinnest feature: for a tube that's the stroke, or the
  // colours part company completely and it turns into a prism demo with a green band
  float extent = min(leaks[0].sh.size.x, leaks[0].sh.size.y);
  if (kind == SH_ARCH || kind == SH_RING) extent = leaks[0].sh.round;
  float dr = hash11(S + 10.0);
  sc.disp = (WP_PARAM_disp >= 0.0 ? WP_PARAM_disp : 0.5 + dr * 1.5) * extent;

  // company: none, a twin, a ghost, or both. a twin is the same lamp reflected once more in the
  // glass — same shape, another colour, overlapping (the pink arch). a ghost is a small far
  // reflection — its own shape, dimmer, less spread (the cyan smudge beside the tombstone)
  float rc = hash11(S + 30.0);
  int n = 1;
  bool twin = (rc > 0.45 && rc < 0.75) || kind == SH_ARCH, ghost = rc >= 0.6;   // an arch is always a pair
  if (twin) {
    Leak t = leaks[0];
    float ta = hash11(S + 31.0) * 6.2831853;
    t.sh.center += float2(cos(ta), sin(ta)) * extent * (0.8 + hash11(S + 32.0) * 0.8);
    t.sh.rot += (hash11(S + 33.0) - 0.5) * 0.4;
    t.sh.size *= 0.85 + hash11(S + 34.0) * 0.3;
    t.tint = clipTint((tint + 1 + int(hash11(S + 35.0) * 5.0)) % 6);
    t.exposure *= 0.6 + hash11(S + 36.0) * 0.6;
    t.grad = -leaks[0].grad;
    leaks[n++] = t;
  }
  if (ghost) {
    Leak g;
    float gs = S + 60.0;
    int gk = hash11(gs) < 0.5 ? SH_BLOB : (hash11(gs + 0.5) < 0.5 ? SH_STREAK : SH_PILL);
    g.sh = makeShape(gk, gs, aspect);
    g.sh.size *= 0.35 + hash11(gs + 1.5) * 0.3;
    g.sh.round *= 0.5;
    g.sh.cut = false;
    // somewhere away from the hero
    float gd = hash11(gs + 2.5) * 6.2831853;
    g.sh.center = leaks[0].sh.center + float2(cos(gd), sin(gd)) * (extent * 1.6 + 0.25);
    g.tint = clipTint(int(hash11(gs + 3.5) * 6.0) % 6);
    g.exposure = leaks[0].exposure * (0.25 + hash11(gs + 4.5) * 0.35);
    g.dispScale = 0.3 + hash11(gs + 5.5) * 0.4;
    g.blurScale = 1.6;
    g.grad = leaks[0].grad;
    leaks[n++] = g;
  }
  sc.n = n;

  // a floor: the lamp sat on something glossy
  sc.reflect = (kind == SH_PILL || kind == SH_SLAB || kind == SH_CONE) && hash11(S + 23.0) < 0.45;
  sc.floorY = leaks[0].sh.center.y - leaks[0].sh.size.y - 0.01;
  return sc;
}

// the light at p from one leak, per wavelength summed to linear rgb
float3 lightAt(Scene sc, Leak lk, float2 p, float S, float strength) {
  const int N = 28;
  float3 acc = 0.0, norm = 0.0;
  for (int i = 0; i < N; i++) {
    float l = 400.0 + (float(i) + 0.5) * (300.0 / float(N));
    float s = dispersion(l);
    float3 rgb = max(xyz2rgb(cieXYZ(l)), 0.0);
    norm += rgb;
    float w = sourceWeight(l, sc.tilt, sc.greenDip);
    float2 q = p - sc.axis * s * sc.disp * lk.dispScale;
    float blur = sc.blur * lk.blurScale * (1.0 + sc.caBlur * abs(s));
    float cov = coverage(shapeSD(lk.sh, q, S), blur);
    acc += rgb * w * cov;
  }
  // the lamp isn't uniform: brighter toward one end, so the interior keeps a gradient
  // instead of clipping to a flat plate
  float grad = 0.55 + 0.45 * smoothstep(-1.0, 1.0, dot(p - lk.sh.center, lk.grad) / max(lk.sh.size.x, lk.sh.size.y));
  return acc / norm * strength * grad * lk.tint * lk.exposure;
}

float4 wp_main(float2 uv, constant Uniforms& u) {
  float S = u.seed;
  float aspect = u.res.x / u.res.y;
  float2 p = (uv - 0.5) * float2(aspect, 1.0);
  Leak leaks[MAX_LEAKS];
  Scene sc = buildScene(S, aspect, leaks);

  float3 light = 0.0;
  for (int i = 0; i < sc.n; i++) light += lightAt(sc, leaks[i], p, S + float(i) * 7.0, 1.0);
  if (sc.reflect && p.y < sc.floorY + 0.02) {
    // mirrored in a glossy floor: dimmer, blurrier, fading with distance, and the floor's edge
    // is itself out of focus
    float2 m = float2(p.x, 2.0 * sc.floorY - p.y);
    float below = sc.floorY - p.y;
    float fall = exp(-below * 8.0) * smoothstep(-0.02, 0.03, below);
    Leak rl = leaks[0];
    rl.blurScale *= 2.5;
    light += lightAt(sc, rl, m, S, 0.22 * fall);
  }

  return float4(light, 1.0);
}

// the lens: nothing in these photos is in focus. gather the light over a defocus disc — a
// rotated spiral of taps, each an area sample from a coarser mip so the disc fills in rather than
// speckles — and only then let the film see it. a corner convolved with a disc is no longer a
// corner, and that's the softness the drawn shapes were missing
float4 wp_post(float2 uv, texture2d<float> scene, constant Uniforms& u) {
  float S = u.seed;
  float aspect = u.res.x / u.res.y;
  Leak leaks[MAX_LEAKS];
  Scene sc = buildScene(S, aspect, leaks);
  float2 px = uv * u.res;
  float R = sc.defocus * u.res.y;
  float rot = hash21(px + hash11(S + 44.0) * 1000.0) * 6.2831853;
  const int N = 48;
  float3 light = 0.0;
  for (int i = 0; i < N; i++) {
    float r = sqrt((float(i) + 0.5) / float(N));
    float a = float(i) * 2.39996323 + rot;
    float2 off = float2(cos(a), sin(a)) * r * R;
    light += wp_scene(scene, uv + off / u.res, log2(max(1.0, 0.45 * R / sqrt(float(N))))).rgb;
  }
  light /= float(N);

  // the film: a shoulder that clips toward each lamp's colour, the base under everything
  float3 col = 1.0 - exp(-light);
  col = sc.base + col * (1.0 - sc.base);
  // a soft vignette from the lens
  float2 v = (uv - 0.5) * float2(aspect, 1.0);
  col *= 1.0 - 0.25 * dot(v, v);
  col = pow(max(col, 0.0), float3(1.0 / 2.2));
  // grain: fine, a little heavier in the shadows, as measured (~2/255 in the base)
  float g = hash21(px + hash11(S + 42.0) * 1000.0) - 0.5;
  col += g * (0.012 + 0.02 * (1.0 - col.g));
  return float4(clamp(col, 0.0, 1.0), 1.0);
}
