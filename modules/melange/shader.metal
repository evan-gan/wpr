// melange: a sprinkle of tiny mirrors glinting over a dark, graded ground. the
// spice must flow.
// after "Diamond Dust" by Tonny Espeset, https://www.shadertoy.com/view/ffKXRw
// ("feel free to use this code, but please keep this credit and link")
//
// how it's built: the ground plane carries an 11-octave fbm pushed through a per-style colour curve
// (style 0 warps it through z^2 first, which is where the figure-eight comes from). a thin slab above
// it holds square particles, eight per 10/512 cell, traced by a DDA walk through the cell grid and lit
// with ggx from two lights so they glint. wp_main returns hdr colour with encoded view depth in alpha;
// wp_post gathers a depth-aware defocus disc, adds bloom from a coarse mip, then aces, grain, grade.
// the original steps through its style generator on a clock; here the seed picks the style, the
// camera's progress along its track, and the spin phase of the particles.

// `wp gen melange --set style=0` forces the classic gold lemniscate; negative = seeded
#ifndef WP_PARAM_style
#define WP_PARAM_style -1.0
#endif
// camera progress along the style's track, 0..1; negative = seeded
#ifndef WP_PARAM_progress
#define WP_PARAM_progress -1.0
#endif
// 1 keeps the ground in spice colours (cinnamon, amber, rust), 0 lets the style roam the whole hue
// wheel; negative = seeded, mostly spice
#ifndef WP_PARAM_spice
#define WP_PARAM_spice -1.0
#endif

constant float DD_PI = 3.141592653589793;
constant float DD_TAU = 6.283185307179586;
constant float DD_HALF = 5.0;
constant float DD_CELL = 10.0 / 512.0;

inline float ddSat(float x) { return clamp(x, 0.0, 1.0); }
inline float ddQuintic(float x) { x = ddSat(x); return x * x * x * (x * (x * 6.0 - 15.0) + 10.0); }

inline uint ddHash(uint v) {
  v ^= 0xa3c59ac3u; v *= 0x9e3779b9u;
  v ^= v >> 16u; v *= 0x9e3779b9u;
  v ^= v >> 16u; v *= 0x9e3779b9u;
  return v;
}
inline float ddRandom(uint seed, uint lane) { return float(ddHash(seed + lane)) * (1.0 / 4294967296.0); }
inline uint ddCellHash(int2 p) {
  uint x = uint(p.x), y = uint(p.y);
  return ddHash(x * 0x8da6b343u ^ y * 0xd8163841u ^ 0xcb1ab31fu);
}
inline float ddLattice(int2 p, uint salt) { return ddRandom(ddCellHash(p) ^ ddHash(salt), 0u); }

float ddNoise(float2 p, uint salt) {
  int2 i = int2(floor(p));
  float2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
  float a = ddLattice(i, salt), b = ddLattice(i + int2(1, 0), salt);
  float c = ddLattice(i + int2(0, 1), salt), d = ddLattice(i + int2(1), salt);
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

inline float3 ddHsv(float3 c) {
  float3 p = abs(fract(c.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
  return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}
inline float ddHueMix(float a, float b, float t) { float d = fract(b - a + 0.5) - 0.5; return fract(a + d * t); }

struct DDStyle {
  float id, family, hue, accentHue, saturation, angle, scale, aspect, warp, persistence, lemniscate;
  float2 offset;
};

inline float ddStyleRandom(float id, uint lane) {
  uint n = uint(max(id, 0.0));
  return ddRandom(ddHash(n * 0x9e3779b9u ^ 0x6d2b79f5u), lane * 0x85ebca6bu);
}

DDStyle ddMakeStyle(float id) {
  DDStyle s;
  float r0 = ddStyleRandom(id, 0u), r1 = ddStyleRandom(id, 1u), r2 = ddStyleRandom(id, 2u);
  float r3 = ddStyleRandom(id, 3u), r4 = ddStyleRandom(id, 4u), r5 = ddStyleRandom(id, 5u);
  float r6 = ddStyleRandom(id, 6u), r7 = ddStyleRandom(id, 7u), r8 = ddStyleRandom(id, 8u);
  bool classic = id < 0.5;
  s.id = id;
  s.family = classic ? 0.0 : fmod(id, 3.0);
  s.hue = classic ? 0.075 : r0;
  float split = r1 < 0.5 ? mix(0.045, 0.12, r2) * (r3 < 0.5 ? -1.0 : 1.0) : mix(0.28, 0.48, r2) * (r3 < 0.5 ? -1.0 : 1.0);
  s.accentHue = classic ? 0.105 : fract(s.hue + split);
  s.saturation = classic ? 0.9 : mix(0.55, 1.0, r4);
  s.angle = classic ? 0.25 : DD_TAU * r5;
  s.scale = classic ? 1.0 : mix(0.82, 1.22, r6);
  s.aspect = classic ? 1.2 : mix(0.78, 1.28, r7);
  s.warp = mix(0.2, 0.38, r8);
  s.persistence = mix(0.57, 0.7, ddStyleRandom(id, 9u));
  s.lemniscate = classic ? 1.0 : 0.0;
  s.offset = classic ? float2(0.07, -0.055) : float2(ddStyleRandom(id, 10u) - 0.5, ddStyleRandom(id, 11u) - 0.5);
  return s;
}

// particle slab geometry per layer: (height range, height centre, size base, size range)
float4 ddLayerGeom(DDStyle s, int layer) {
  float jitter = s.id < 0.5 ? 0.0 : (ddStyleRandom(s.id, uint(20 + layer)) - 0.5) * 0.002;
  if (layer == 0) {
    float y = mix(0.0358276367, 0.0315, step(0.5, s.family) * step(s.family, 1.5)) + jitter;
    return float4(0.049987793, y, 0.0392156877, 0.0196078438);
  }
  return float4(0.049987793, 0.0374450684 + jitter, 0.0313725509, 0.0156862754);
}
inline float3 ddLayerSpin(int layer) {
  return layer == 0 ? float3(0.0196078438, 0.0078431377, 1.0) : float3(0.0078431377, 0.0039215689, 1.0);
}

struct DDCamera { float3 eye, right, up, forward; };

// the demo's three camera tracks, one per style family; `amount` is the progress along the track
float ddSourceTime(DDStyle s, float amount) {
  float start = s.family < 0.5 ? 60.9708333333 : (s.family < 1.5 ? 68.5708333333 : 76.2041666667);
  float end = s.family < 0.5 ? 68.5583333333 : (s.family < 1.5 ? 76.1916666667 : 82.8583333333);
  return mix(start, end, amount);
}

DDCamera ddStyleCamera(DDStyle s, float amount) {
  DDCamera c;
  float source = ddSourceTime(s, amount);
  float3 eye, rate, right, anchorUp, anchorForward;
  float anchor, angleRate;
  if (s.family < 0.5) {
    eye = float3(-0.0844116211, 2.259765625, -3.93310115);
    rate = float3(0.0, 0.0, 0.19489053); anchor = 64.0; angleRate = -0.0064827;
    right = float3(0.9999419451, 0.0000004396, -0.0107735042);
    anchorUp = float3(0.007421071, 0.7248959541, 0.6888220906);
    anchorForward = float3(0.0078100003, -0.6888620257, 0.7248538733);
  } else if (s.family < 1.5) {
    eye = float3(-1.26171875, 2.259765625, 1.330246925);
    rate = float3(0.0, 0.0, -0.23956955); anchor = 73.8; angleRate = 0.0;
    right = float3(-0.3833194971, 0.0000357628, -0.9237259626);
    anchorUp = float3(0.7119913101, 0.6370837688, -0.2953743935);
    anchorForward = float3(0.5885049105, -0.7708292007, -0.2442690134);
  } else {
    eye = float3(-2.22008, 1.08691, 1.87843);
    rate = float3(-0.14209, 0.0, -0.05918); anchor = 79.5; angleRate = 0.0;
    right = float3(-0.1682394748, 0.0, -0.9857461535);
    anchorUp = float3(0.5283690578, 0.8442121075, -0.090177915);
    anchorForward = float3(0.8321788377, -0.5360092514, -0.1420298016);
  }
  if (s.id > 0.5) {
    eye.x += (ddStyleRandom(s.id, 30u) - 0.5) * 0.6;
    eye.y *= mix(0.92, 1.08, ddStyleRandom(s.id, 31u));
    eye.z += (ddStyleRandom(s.id, 32u) - 0.5) * 0.6;
    rate *= mix(0.86, 1.14, ddStyleRandom(s.id, 33u));
    angleRate += mix(-0.0012, 0.0012, ddStyleRandom(s.id, 34u));
  }
  float delta = angleRate * (source - anchor), co = cos(delta), si = sin(delta);
  c.eye = eye + rate * (source - anchor);
  c.right = right;
  c.up = anchorUp * co + anchorForward * si;
  c.forward = -anchorUp * si + anchorForward * co;
  return c;
}

struct DDPost { float focusControl, apertureControl, strengthControl; float3 bloomTint; };

DDPost ddPostForStyle(DDStyle s, float amount) {
  DDPost p;
  float source = ddSourceTime(s, amount), progress;
  if (s.family < 0.5) p.focusControl = 0.445068359375;
  else if (s.family < 1.5) { progress = ddSat((source - 68.5708333333) / (76.1708333333 - 68.5708333333)); p.focusControl = mix(0.3770463467, 0.4620649815, progress); }
  else { progress = ddSat((source - 76.2041666667) / (82.8333333333 - 76.2041666667)); p.focusControl = mix(0.3938723803, 0.2838296592, progress); }
  if (s.id > 0.5) p.focusControl *= mix(0.96, 1.04, ddStyleRandom(s.id, 41u));
  p.apertureControl = s.family < 0.5 ? 0.7882353067 : (s.family < 1.5 ? 1.0 : 0.7882353067);
  if (s.id > 0.5) p.apertureControl *= mix(0.94, 1.06, ddStyleRandom(s.id, 42u));
  p.strengthControl = 1.0;
  p.bloomTint = s.id < 0.5 ? float3(1.0, 0.5960784554, 0.4235294163)
                           : ddHsv(float3(s.accentHue, mix(0.1, 0.3, ddStyleRandom(s.id, 44u)), 1.0));
  return p;
}

inline float ddEncodeDepth(float viewDepth) { return 0.01 / max(viewDepth, 1e-6); }
inline float ddDepthDistance(float encoded) { return encoded > 0.0 ? 1.0 + 0.01 / encoded : 1e6; }
inline float ddSceneDistance(texture2d<float> scene, float2 uv) { return ddDepthDistance(wp_scene(scene, uv, 0.0).a); }

float ddDofWeight(texture2d<float> scene, float2 uv, float centerCoc, float centerDistance, float neighbourCoc) {
  float weight = ddSceneDistance(scene, uv) < centerDistance ? neighbourCoc * (0.16078431904315948 * 255.0) : 1.0;
  if (!(centerCoc > neighbourCoc + 0.062745101749897 / 10.0)) weight = 1.0;
  return clamp(weight, 0.0, 1.0);
}

// ---- ground pattern -------------------------------------------------------------------------

inline float3 ddQ16(float3 x) { return floor(clamp(x, 0.0, 1.0) * 65535.0 + 0.5) / 65535.0; }

// the classic style's first three fbm octaves and warp field are baked tables, so style 0 is exactly
// the demo's opening frame rather than a hash of it
constant uint DD_M0[16] = {13583506u,4302259u,9375848u,3760279u,1293914u,12796088u,7621060u,4619105u,11796310u,14267733u,16736504u,3913519u,12221407u,7709230u,4784939u,7637972u};
constant uint DD_M1[64] = {894534u,3691408u,16212986u,12289726u,3917870u,3482626u,10361558u,12896808u,11163277u,11311954u,10534552u,4022337u,15249849u,3984717u,14332226u,15388633u,5467076u,8041620u,1425578u,8748189u,11736132u,6114724u,3925316u,9649554u,5913604u,13814163u,14262870u,13382240u,735953u,13127685u,8811692u,3420810u,1338139u,5388781u,1619973u,10020941u,10414472u,2942636u,6091787u,2632613u,4851227u,6131202u,13303864u,13312501u,1750933u,12438069u,6922519u,7844630u,9773712u,266405u,8337675u,13932559u,747613u,12470608u,8688788u,5080459u,13020988u,15701960u,3041234u,14720637u,10956200u,9029648u,8267144u,327074u};
constant uint DD_M2[256] = {13238908u,12819089u,2679431u,11320207u,1302547u,13007019u,14407461u,15461898u,15634816u,8026035u,4338339u,11418224u,8292762u,1608318u,14529306u,11299905u,13783475u,1487149u,1094910u,9764723u,5098967u,12899896u,107080u,3944117u,4491016u,2842420u,10928345u,10373085u,14888901u,6277901u,4101801u,13255072u,13978039u,15143947u,2566582u,8465729u,12115505u,10588789u,8268871u,13922544u,4823278u,1878543u,14386713u,14572689u,7322779u,5879803u,850671u,6120017u,14832283u,1324043u,2994778u,15164014u,15800098u,9800194u,4599098u,13831190u,14817460u,9688078u,14331876u,10398198u,9362428u,14888114u,3889152u,5834822u,9885689u,12423033u,1174646u,1441437u,8982420u,11550771u,12697550u,2448049u,14542659u,6883581u,6422230u,12384131u,9903746u,13595181u,11207565u,6395198u,13965172u,7860313u,10889733u,15977841u,529931u,16575171u,14944129u,13656860u,5675516u,12560490u,11583500u,9473077u,6626734u,7662167u,14839327u,5343024u,7590162u,8033728u,13050257u,12332392u,12866415u,13464807u,15697172u,8068479u,845697u,4782132u,12364804u,9466382u,3363300u,2727828u,9395464u,1394758u,10772564u,1129273u,14859660u,11359992u,6503512u,8831185u,6000763u,14271530u,7967314u,2632411u,2301180u,12215421u,7673675u,5552956u,8684604u,14485533u,10877370u,15471718u,6820994u,15642379u,13432377u,10652720u,10106172u,12941269u,16051525u,12528637u,5722158u,11974330u,16280350u,13591573u,15186626u,4192542u,5486653u,3995794u,3086677u,13879450u,4212491u,2394298u,9128688u,10905238u,13175085u,12646739u,11248647u,14947086u,7549910u,16243124u,1488091u,14802982u,7267909u,9667712u,9959208u,1255388u,13021473u,13050734u,6085616u,6371322u,15801500u,8359497u,10936887u,12215352u,11975705u,1062737u,8720686u,16740681u,3045851u,4570589u,12421992u,1072558u,10885749u,7798146u,15749240u,12847081u,6859354u,15705309u,12551389u,15008893u,9316938u,4039068u,2708272u,16504275u,11701989u,3974605u,6862336u,5358565u,8889880u,10377319u,6390285u,9342826u,8989395u,4284862u,13936994u,1227106u,2326787u,9311452u,34559u,7369169u,6150497u,22388u,16120188u,14764340u,16489766u,14798584u,12156622u,6362027u,16524238u,6734998u,2109640u,1516572u,8132493u,13318614u,6150137u,906231u,1937172u,7260034u,3343202u,15706879u,13232103u,11868066u,13817169u,9278774u,9040873u,11633662u,83726u,1550819u,15563212u,15148194u,12113533u,3470612u,3036977u,15540128u,6181362u,5750274u,15683096u,9217750u,8749927u,5264526u,9828054u,11147378u,11101611u,14587791u,241289u,14048590u,13390254u,5729833u};
constant uint DD_W0[16] = {25u,83u,24u,159u,253u,90u,198u,86u,247u,223u,131u,10u,16u,252u,132u,146u};

inline float3 ddBytes(uint v) { return float3(v & 255u, (v >> 8u) & 255u, (v >> 16u) & 255u) / 255.0; }

float2 ddPatternUv(DDStyle s, float2 xz) {
  float2 uv = float2(xz.x * 0.1 + 0.5, 0.5 - xz.y * 0.1), q = uv - 0.5;
  if (s.lemniscate > 0.5) {
    q -= float2(0.0, 0.14);
    return float2(0.245, 0.615) + float2(q.x * q.x - q.y * q.y - 0.0169, 2.0 * q.x * q.y) * float2(1.18, 3.4);
  }
  float root = sqrt(s.aspect), co = cos(s.angle), si = sin(s.angle);
  q *= float2(s.scale * root, s.scale / root);
  q = float2(co * q.x - si * q.y, si * q.x + co * q.y);
  return q + 0.5 + s.offset;
}

inline int2 ddGraphWrap(int2 p, int period) { return p & int2(period - 1); }

uint ddGraphSeed(DDStyle s, uint stream, uint block) {
  uint familySeed = stream == 0u ? 8u : (stream == 1u ? 34u : 2u);
  uint sourceBlock = stream == 2u ? block + 9u : block;
  if (s.id > 0.5) familySeed = ddHash(familySeed ^ uint(s.id) * 0x9e3779b9u);
  return ddHash(familySeed * 0x85ebca6bu ^ sourceBlock * 0xc2b2ae35u ^ stream * 0x27d4eb2fu);
}

inline uint3 ddHash3(uint3 v) {
  v ^= uint3(0xa3c59ac3u); v *= uint3(0x9e3779b9u);
  v ^= v >> uint3(16u); v *= uint3(0x9e3779b9u);
  v ^= v >> uint3(16u); v *= uint3(0x9e3779b9u);
  return v;
}
inline float3 ddRandom3(uint seed, uint lane) {
  return float3(ddHash3(uint3(seed) + uint3(lane, lane + 1u, lane + 2u))) * (1.0 / 4294967296.0);
}
inline float3 ddGraphTexel(int2 p, uint salt) { return ddRandom3(ddCellHash(p) ^ salt, 0u); }

float3 ddGraphNoise(float2 p, float frequency, uint salt) {
  float2 q = p * frequency, f = fract(q); f = f * f * (3.0 - 2.0 * f);
  int period = int(frequency);
  int2 i = ddGraphWrap(int2(floor(q)), period);
  int2 n = (i + 1) & int2(period - 1);
  float3 a = ddGraphTexel(i, salt), b = ddGraphTexel(int2(n.x, i.y), salt);
  float3 c = ddGraphTexel(int2(i.x, n.y), salt), d = ddGraphTexel(n, salt);
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float3 ddOpeningTexel(int2 p, int octave) {
  int period = 4 << octave, index = p.y * period + p.x;
  if (octave == 0) return ddBytes(DD_M0[index]);
  if (octave == 1) return ddBytes(DD_M1[index]);
  return ddBytes(DD_M2[index]);
}

float3 ddOpeningNoise(float2 p, int octave) {
  int period = 4 << octave;
  float2 q = p * float(period), f = fract(q); f = f * f * (3.0 - 2.0 * f);
  int2 i = ddGraphWrap(int2(floor(q)), period);
  int2 n = (i + 1) & int2(period - 1);
  float3 A = ddOpeningTexel(i, octave), B = ddOpeningTexel(int2(n.x, i.y), octave);
  float3 C = ddOpeningTexel(int2(i.x, n.y), octave), D = ddOpeningTexel(n, octave);
  return mix(mix(A, B, f.x), mix(C, D, f.x), f.y);
}

float3 ddGraphFbm(float2 p, DDStyle s, float persistence) {
  float3 value = float3(0.5);
  float frequency = 4.0, weight = 1.0;
  for (int octave = 0; octave < 11; octave++) {
    float3 noise = (s.id < 0.5 && octave < 3) ? ddOpeningNoise(p, octave)
                                              : ddGraphNoise(p, frequency, ddGraphSeed(s, 0u, uint(octave)));
    value = ddQ16(octave == 0 ? noise : value + (noise - 0.5) * weight);
    frequency *= 2.0; weight *= persistence;
  }
  return value;
}

inline float3 ddGraphCubic(float3 p0, float3 p1, float3 p2, float3 p3, float amount) {
  float3 slope = p3 - p2 - p0 + p1;
  return ((slope * amount + (p0 - p1 - slope)) * amount + (p2 - p0)) * amount + p1;
}

float3 ddGraphWarpRow(float2 p, DDStyle s, int row) {
  float2 q = p * 4.0;
  int2 i = int2(floor(q)) + int2(0, row);
  float amount = fract(q.x);
  uint salt = ddGraphSeed(s, 1u, 0u);
  int2 a = ddGraphWrap(i, 4), b = int2((a.x + 1) & 3, a.y), c = int2((a.x + 2) & 3, a.y), d = int2((a.x + 3) & 3, a.y);
  float3 A, B, C, D;
  if (s.id < 0.5) {
    A = ddBytes(DD_W0[a.y * 4 + a.x]); B = ddBytes(DD_W0[b.y * 4 + b.x]);
    C = ddBytes(DD_W0[c.y * 4 + c.x]); D = ddBytes(DD_W0[d.y * 4 + d.x]);
  } else {
    A = ddGraphTexel(a, salt); B = ddGraphTexel(b, salt); C = ddGraphTexel(c, salt); D = ddGraphTexel(d, salt);
  }
  return ddQ16(ddGraphCubic(A, B, C, D, amount));
}

float3 ddGraphWarp(float2 p, DDStyle s) {
  float amount = fract(p.y * 4.0);
  return ddQ16(ddGraphCubic(ddGraphWarpRow(p, s, 0), ddGraphWarpRow(p, s, 1), ddGraphWarpRow(p, s, 2), ddGraphWarpRow(p, s, 3), amount));
}

float3 ddGraphRgbToHsv(float3 c) {
  float value = max(c.r, max(c.g, c.b)), low = min(c.r, min(c.g, c.b));
  float delta = value - low;
  float saturation = value != 0.0 ? delta / value : 0.0;
  float3 dist = value - c;
  float hue = (dist.z - dist.y) / delta;
  if (c.g == value) hue = (dist.x - dist.z) / delta + 2.0;
  if (c.b == value) hue = (dist.y - dist.x) / delta + 4.0;
  if (delta == 0.0) hue = -1.0;
  return float3(clamp(hue / 6.0, 0.0, 1.0), saturation, value);
}

inline float ddGraphBezier(float t, float a, float b, float c, float d) {
  float u = 1.0 - t;
  return u * u * u * a + 3.0 * u * u * t * b + 3.0 * u * t * t * c + t * t * t * d;
}

float ddGraphCurveSegment(float x, float x0, float x1, float x2, float x3, float y0, float y1, float y2, float y3) {
  float lo = 0.0, hi = 1.0, t = 0.5;
  for (int i = 0; i < 4; i++) { t = (lo + hi) * 0.5; if (ddGraphBezier(t, x0, x1, x2, x3) < x) lo = t; else hi = t; }
  for (int i = 0; i < 10; i++) {
    float u = 1.0 - t;
    float derivative = 3.0 * u * u * (x1 - x0) + 6.0 * u * t * (x2 - x1) + 3.0 * t * t * (x3 - x2);
    t -= (ddGraphBezier(t, x0, x1, x2, x3) - x) / derivative;
  }
  return ddGraphBezier(t, y0, y1, y2, y3);
}

float ddGraphBaseValue(float x, float first, float middle, float last) {
  if (x <= 0.0) return first;
  if (x >= 1.0) return last;
  if (x < 0.5625) return ddGraphCurveSegment(x, 0.0, 42.0 / 255.0, 0.5625 - 16.0 / 255.0, 0.5625, first, first, middle + 0.033416748046875, middle);
  return ddGraphCurveSegment(x, 0.5625, 0.5625 + 16.0 / 255.0, 1.0 - 28.0 / 255.0, 1.0, middle, middle - 0.033416748046875, last - 0.0267486572265625, last);
}

// the per-family colour grade of the ground: hue remapped into a narrow band, value through a curve
float3 ddGraphBaseCurve(DDStyle s, float3 rgb) {
  float3 hsv = ddGraphRgbToHsv(rgb);
  float anchor, first, middle, last;
  if (s.family < 0.5) { hsv.x = mix(1.125, 1.0380859375, hsv.x); hsv.y *= 0.82421875; first = 0.625; middle = 0.0758056640625; last = 0.0712890625; anchor = 1.08154296875; }
  else if (s.family < 1.5) { hsv.x = mix(0.375, 0.625, hsv.x); hsv.y *= 0.66845703125; first = 0.58251953125; middle = 0.0758056640625; last = 0.0625; anchor = 0.5; }
  else { hsv.x = mix(0.11553955078125, 0.83642578125, hsv.x); hsv.y = 0.0; first = 0.625; middle = 0.0758056640625; last = 0.0712890625; anchor = 0.475982666015625; }
  hsv.z = ddGraphBaseValue(hsv.z, first, middle, last);
  if (s.id > 0.5) { hsv.x += s.hue - anchor; hsv.y = clamp(hsv.y * s.saturation + 0.08 * s.saturation, 0.0, 1.0); }
  return ddQ16(ddHsv(hsv));
}

float3 ddGraphEmitterCurve(DDStyle s, float3 rgb, int layer) {
  float3 hsv = ddGraphRgbToHsv(rgb);
  float threshold = layer == 0 ? 0.01953125 : 0.04296875;
  float peak = layer == 0 ? 2.3515625 : 1.2001953125;
  if (s.family > 0.5 && s.family < 1.5) { threshold = layer == 0 ? 0.01953125 : 0.05078125; peak = layer == 0 ? 1.3681640625 : 1.2001953125; }
  hsv.z = max(hsv.z - threshold, 0.0) * peak / (1.0 - threshold);
  if (s.id > 0.5) hsv.x = ddHueMix(hsv.x, layer == 0 ? s.hue : s.accentHue, layer == 0 ? 0.25 : 0.45);
  return ddQ16(ddHsv(hsv));
}

float3 ddStyleBase(DDStyle s, float2 xz) {
  float2 p = fract(ddPatternUv(s, xz));
  float persistence = s.id < 0.5 ? 164.0 / 255.0 : s.persistence;
  float2 repeat = s.family < 0.5 ? float2(3.0, 1.0) : (s.family < 1.5 ? float2(6.0, 1.0) : float2(3.0, 1.0));
  float3 warp = ddQ16(ddGraphWarp(fract(p * repeat), s));
  float angle = warp.r * 6.28, amount = s.id < 0.5 ? 78.0 / 255.0 : s.warp;
  float3 distorted = ddQ16(ddGraphFbm(p + float2(cos(angle), sin(angle)) * amount, s, persistence));
  float3 curved = ddGraphBaseCurve(s, distorted);
  float detailPersistence = s.id < 0.5 ? 102.0 / 255.0 : mix(0.3, 0.52, ddStyleRandom(s.id, 14u));
  float3 detail = ddQ16(ddGraphNoise(p, 2048.0, ddGraphSeed(s, 2u, 0u)));
  detail = ddQ16(detail + (ddGraphNoise(p, 4096.0, ddGraphSeed(s, 2u, 1u)) - 0.5) * detailPersistence);
  float contrast = s.id < 0.5 ? 21.0 / 255.0 : mix(17.0, 25.0, ddStyleRandom(s.id, 15u)) / 255.0;
  detail = ddQ16(mix(float3(0.5), detail, contrast * contrast * 45.0));
  // overlay blend of the detail onto the graded base
  return ddQ16(select(1.0 - 2.0 * (1.0 - curved) * (1.0 - detail), 2.0 * curved * detail, curved < 0.5));
}

// base pattern (layer < 0) or the emitter pigment of one particle
float3 ddSurface(float2 xz, DDStyle s, int layer) {
  float3 value = ddStyleBase(s, xz);
  if (layer >= 0) value = ddGraphEmitterCurve(s, value, layer);
  return value;
}

inline float ddEdgeFade(float2 xz) { return smoothstep(0.0, 0.6, DD_HALF - max(abs(xz.x), abs(xz.y))); }

// ---- particles ------------------------------------------------------------------------------

float3x3 ddRotation(float angle, float3 axis) {
  float c = cos(angle), s = sin(angle), t = 1.0 - c;
  float3 n = normalize(axis);
  return float3x3(float3(t * n.x * n.x + c, t * n.x * n.y + s * n.z, t * n.x * n.z - s * n.y),
                  float3(t * n.x * n.y - s * n.z, t * n.y * n.y + c, t * n.y * n.z + s * n.x),
                  float3(t * n.x * n.z + s * n.y, t * n.y * n.z - s * n.x, t * n.z * n.z + c));
}

inline float3 ddFresnel(float cosine, float3 f0) { return f0 + (1.0 - f0) * pow(max(1.0 - cosine, 0.0), 5.0); }
inline float ddGgx(float NoH, float roughness) { float a2 = roughness * roughness, d = NoH * NoH * (a2 - 1.0) + 1.0; return a2 / (DD_PI * d * d); }
inline float ddSmith(float NoV, float NoL, float roughness) {
  float a2 = roughness * roughness;
  float gv = NoL * sqrt(NoV * NoV * (1.0 - a2) + a2);
  float gl = NoV * sqrt(NoL * NoL * (1.0 - a2) + a2);
  return 0.5 / max(gv + gl, 0.0001);
}

constant float DD_BRDF_LOW[32] = {0.963485579,0.927107471,0.900337964,0.883154088,0.874827313,0.872618822,0.874337569,0.878454942,0.884102723,0.890457196,0.897530086,0.904364995,0.911172523,0.917560591,0.92333964,0.928835802,0.933787648,0.93809043,0.942026013,0.945628572,0.94875777,0.951823748,0.954590956,0.956919742,0.959003824,0.960959041,0.962808697,0.964451634,0.965854815,0.967271737,0.968507921,0.969594822};
constant float DD_BRDF_HIGH[32] = {0.935543537,0.856176674,0.797831237,0.749926031,0.709445238,0.674226046,0.643178701,0.61544776,0.59042716,0.567594469,0.546785951,0.527685225,0.509999931,0.49359557,0.478318483,0.464052081,0.45069164,0.438145876,0.426344514,0.415208369,0.40469411,0.394740194,0.385292202,0.37631771,0.367791981,0.359659016,0.351913631,0.344512403,0.337443024,0.330670536,0.324181944,0.317962229};

float ddBrdfRow(float NoV, bool high) {
  float x = clamp(NoV * 32.0 - 0.5, 0.0, 31.0);
  int a = int(floor(x)), b = min(a + 1, 31);
  return mix(high ? DD_BRDF_HIGH[a] : DD_BRDF_LOW[a], high ? DD_BRDF_HIGH[b] : DD_BRDF_LOW[b], fract(x));
}
inline float ddSplitEnergy(float NoV, float roughness) {
  const float low = (100.0 / 255.0) * (100.0 / 255.0);
  return mix(ddBrdfRow(NoV, false), ddBrdfRow(NoV, true), clamp((roughness - low) / (1.0 - low), 0.0, 1.0));
}

float3 ddLight(float3 lightDirection, float3 lightColour, float3 viewDirection, float3 normal, float3 albedo, float roughness) {
  float3 halfDirection = normalize(lightDirection + viewDirection);
  float VoH = dot(halfDirection, viewDirection);
  float NoL = clamp(dot(normal, lightDirection), 0.0, 1.0);
  float NoV = clamp(dot(normal, viewDirection), 0.0, 1.0);
  float NoH = dot(normal, halfDirection);
  float3 f = ddFresnel(VoH, albedo);
  float energy = ddSplitEnergy(NoV, roughness);
  float3 multiple = f * (1.0 + albedo * (1.0 - energy) / energy);
  return multiple * ddGgx(NoH, roughness) * ddSmith(NoV, NoL, roughness) * NoL * lightColour;
}

float3 ddLayerTint(DDStyle s, int layer, float3 randomTint) {
  float3 base, spread;
  if (s.family < 0.5) { base = float3(1.0); spread = layer == 0 ? float3(0.0) : float3(8.0); }
  else if (s.family < 1.5) { base = layer == 0 ? float3(3.0) : float3(6.0, 2.353515625, 0.49853515625); spread = layer == 0 ? float3(0.0) : float3(8.0, 5.98828125, 12.0); }
  else { base = layer == 0 ? float3(1.0) : float3(2.0); spread = layer == 0 ? float3(0.0) : float3(2.337890625, 4.78515625, 6.0); }
  if (s.id > 0.5) {
    float3 target = ddHsv(float3(layer == 0 ? s.hue : s.accentHue, layer == 0 ? mix(0.28, 0.62, ddStyleRandom(s.id, 46u)) : mix(0.4, 0.82, ddStyleRandom(s.id, 47u)), 1.0));
    float amount = layer == 0 ? 0.1 : 0.2, mean = (base.r + base.g + base.b) / 3.0, targetMean = (target.r + target.g + target.b) / 3.0;
    float exposure = mix(layer == 0 ? 0.97 : 0.94, layer == 0 ? 1.03 : 1.06, ddStyleRandom(s.id, uint(48 + layer)));
    base = mean * mix(base / max(mean, 1e-4), target / max(targetMean, 1e-4), amount) * exposure;
    amount = layer == 0 ? 0.1 : 0.28; mean = (spread.r + spread.g + spread.b) / 3.0;
    if (mean > 1e-4) spread = mean * mix(spread / mean, target / max(targetMean, 1e-4), amount) * exposure;
  }
  return base + randomTint * spread;
}

struct DDHit { float t, limit; float3 normal, centre; uint seed; int layer; };

void ddParticle(int2 cell, uint cellHash, int slot, int layer, float3 ro, float3 rd, float4 geom, float spinTime, thread DDHit& hit) {
  uint seed = ddHash(cellHash ^ uint(slot) * 0x9e3779b9u ^ uint(layer + 1) * 0x85ebca6bu);
  if (ddRandom(seed, 31u) >= 0.5) return;
  float2 centreXZ = -float2(DD_HALF) + (float2(cell) + float2(ddRandom(seed, 0u), ddRandom(seed, 2u))) * DD_CELL;
  float3 centre = float3(centreXZ.x, (ddRandom(seed, 1u) - 0.5) * geom.x + geom.y, centreXZ.y);
  if (ddRandom(seed, 22u) >= ddEdgeFade(centre.xz)) return;
  float size = ddRandom(seed, 15u) * geom.w + geom.z, halfSize = size * 0.1;
  float3 axis = ddRandom3(seed, 19u);
  float3 spinv = ddLayerSpin(layer);
  float spin = (ddRandom(seed, 17u) * spinv.y + spinv.x) * 0.5;
  if (ddRandom(seed, 18u) < 0.5) spin = -spin;
  float angle = (ddRandom(seed, 16u) * 2.0 - 1.0) * spinv.z * (4.0 * DD_PI);
  angle += spin * (84.0 + spinTime * 30.0 - 43.5202143);
  angle -= DD_TAU * floor(angle / DD_TAU);
  float3x3 rotation = ddRotation(angle, axis);
  float3 n = rotation[2];
  float denominator = dot(n, rd);
  if (abs(denominator) < 1e-9) return;
  float distance = dot(n, centre - ro) / denominator;
  if (distance <= 0.0 || distance >= hit.limit) return;
  float3 localPoint = ro + distance * rd - centre;
  float2 square = float2(dot(localPoint, rotation[0]), dot(localPoint, rotation[1])) / halfSize;
  if (any(abs(square) > float2(1.0))) return;
  if (hit.layer >= 0 && distance >= hit.t) return;
  if (dot(normalize(centre - ro), n) > 0.0) n = -n;
  hit.t = distance; hit.normal = normalize(n); hit.centre = centre; hit.seed = seed; hit.layer = layer;
}

void ddTraceParticles(float3 ro, float3 rd, DDStyle s, float spinTime, thread DDHit& hit) {
  if (abs(rd.y) < 1e-8) return;
  float tHigh = (0.08 - ro.y) / rd.y, tLow = (-0.02 - ro.y) / rd.y;
  float enter = max(min(tHigh, tLow), 0.0), leave = min(max(tHigh, tLow), hit.limit);
  if (leave <= enter) return;
  float4 geom0 = ddLayerGeom(s, 0), geom1 = ddLayerGeom(s, 1);
  float2 p0 = (ro.xz + rd.xz * enter + float2(DD_HALF)) / DD_CELL;
  int2 cell = int2(floor(p0));
  float2 direction = sign(rd.xz);
  float2 safeRay = float2(abs(rd.x) < 1e-9 ? (rd.x < 0.0 ? -1e-9 : 1e-9) : rd.x,
                          abs(rd.z) < 1e-9 ? (rd.z < 0.0 ? -1e-9 : 1e-9) : rd.z);
  float2 delta = abs(float2(DD_CELL) / safeRay);
  float2 nextDistance = (float2(cell) + max(direction, float2(0.0)) - p0) * DD_CELL / safeRay;
  nextDistance = select(nextDistance, float2(1e30), direction == float2(0.0));
  for (int stepIndex = 0; stepIndex < 48; stepIndex++) {
    if (cell.x < 0 || cell.y < 0 || cell.x >= 512 || cell.y >= 512) break;
    uint cellHash = ddCellHash(cell);
    for (int particle = 0; particle < 8; particle++)
      ddParticle(cell, cellHash, particle & 3, particle >> 2, ro, rd, particle < 4 ? geom0 : geom1, spinTime, hit);
    float boundary = enter + min(nextDistance.x, nextDistance.y);
    if (boundary >= leave || (hit.layer >= 0 && hit.t <= boundary)) break;
    if (nextDistance.x < nextDistance.y) { nextDistance.x += delta.x; cell.x += int(direction.x); }
    else { nextDistance.y += delta.y; cell.y += int(direction.y); }
  }
}

float3 ddRay(DDCamera camera, float2 fragCoord, float2 res) {
  float2 ndc = fragCoord / res * 2.0 - 1.0;
  float projectionY = 2.414213419, projectionX = projectionY / (res.x / res.y);
  return normalize(camera.right * (ndc.x / projectionX) + camera.up * (ndc.y / projectionY) + camera.forward);
}

float ddGroundHit(float3 ro, float3 rd) {
  if (rd.y >= 0.0) return 1e30;
  float distance = -ro.y / rd.y;
  float3 point = ro + distance * rd;
  return distance > 0.0 && abs(point.x) <= DD_HALF && abs(point.z) <= DD_HALF ? distance : 1e30;
}

float3 ddParticleLight(DDHit hit, float3 ro, float3 rd, DDStyle s, float3 pigment) {
  float3 randomTint = ddRandom3(hit.seed, 11u);
  float3 tint = ddLayerTint(s, hit.layer, randomTint);
  float3 albedo = (127.0 / 255.0) * pigment * tint, point = ro + hit.t * rd, viewDirection = normalize(ro - point);
  float roughness = hit.layer == 0 ? 1.0 : 100.0 / 255.0; roughness *= roughness;
  float particleGain = s.id < 0.5 ? 1.0 : (s.family < 0.5 ? 2.0 : (s.family < 1.5 ? 1.0 : 1.2));
  float3 lit = ddLight(normalize(float3(0.50373936, 0.69598544, -0.51169336)), float3(10.0), viewDirection, hit.normal, albedo, roughness);
  lit += ddLight(normalize(float3(0.04815805, -0.39421037, -0.91776264)), float3(4.5), viewDirection, hit.normal, albedo, roughness);
  return lit * particleGain;
}

// ---- seed -> scene --------------------------------------------------------------------------

struct DDSetup { DDStyle style; DDCamera camera; float amount, spinTime; };

DDSetup ddSetup(constant Uniforms& u) {
  DDSetup d;
  float id = WP_PARAM_style;
  if (id < 0.0) id = hash11(u.seed) < 0.3 ? 0.0 : floor(hash11(u.seed + 1.0) * 100000.0);
  d.style = ddMakeStyle(id);
  // the spice: hue held in the cinnamon-to-gold band, accent a little warmer or redder, saturation up.
  // the glints keep their own random tints, so the rainbow stays in the sparkle and not the ground
  float spice = WP_PARAM_spice;
  if (spice < 0.0) spice = hash11(u.seed + 5.0) < 0.7 ? 1.0 : 0.0;
  if (spice > 0.5 && id > 0.5) {
    float r0 = hash11(u.seed + 6.0), r1 = hash11(u.seed + 7.0), r2 = hash11(u.seed + 8.0);
    d.style.hue = mix(0.03, 0.11, r0);
    d.style.accentHue = fract(d.style.hue + mix(0.03, 0.09, r1) * (r2 < 0.5 ? -1.0 : 1.0));
    d.style.saturation = mix(0.8, 1.0, hash11(u.seed + 9.0));
  }
  float amount = WP_PARAM_progress;
  if (amount < 0.0) amount = hash11(u.seed + 2.0);
  d.amount = ddSat(amount + u.time * 0.02);
  d.spinTime = hash11(u.seed + 3.0) * 600.0 + u.time;
  d.camera = ddStyleCamera(d.style, d.amount);
  return d;
}

float4 wp_main(float2 uv, constant Uniforms& u) {
  DDSetup d = ddSetup(u);
  float2 fragCoord = uv * u.res;
  float3 ro = d.camera.eye, centerRay = ddRay(d.camera, fragCoord, u.res);
  float centerGround = ddGroundHit(ro, centerRay);
  float3 colour = float3(0.0), sparkle = float3(0.0);
  DDHit centerHit;
  centerHit.t = centerGround;
  // sample 0 is the centre ray: its hit sets the depth and its ground point the base colour.
  // samples 1-4 are corner rays whose particle hits add sparkle
  for (int sampleIndex = 0; sampleIndex < 5; sampleIndex++) {
    bool center = sampleIndex == 0;
    int corner = max(sampleIndex - 1, 0);
    float2 offset = center ? float2(0.0) : (float2(float(corner & 1), float(corner >> 1)) - 0.5) * 0.5;
    float3 rd = center ? centerRay : ddRay(d.camera, fragCoord + offset, u.res);
    float groundDistance = center ? centerGround : ddGroundHit(ro, rd);
    DDHit hit;
    hit.t = groundDistance; hit.limit = groundDistance; hit.normal = float3(0.0, 1.0, 0.0); hit.centre = float3(0.0); hit.seed = 0u; hit.layer = -1;
    ddTraceParticles(ro, rd, d.style, d.spinTime, hit);
    if (center) centerHit = hit;
    bool ground = center && centerGround < 1e29, particle = !center && hit.layer >= 0;
    if (!(ground || particle)) continue;
    float2 xz = ground ? (ro + centerGround * centerRay).xz : hit.centre.xz;
    float3 surface = ddSurface(xz, d.style, ground ? -1 : hit.layer);
    if (ground) colour = surface * ddEdgeFade(xz);
    else sparkle += ddParticleLight(hit, ro, rd, d.style, surface) * 0.25;
  }
  colour += sparkle;
  float depth = centerHit.t;
  if (depth < 1e29) {
    float3 point = ro + depth * centerRay;
    return float4(colour, ddEncodeDepth(dot(point - ro, d.camera.forward)));
  }
  return float4(0.0);
}

// ---- post: defocus, bloom, tonemap, grain, grade -----------------------------------------------

float ddCoc(float encodedDepth, DDPost post) {
  float focus = post.focusControl * 10.0, aperture = post.apertureControl / 10.0, distance = ddDepthDistance(encodedDepth);
  float safeDistance = abs(distance) < 1e-8 ? (distance < 0.0 ? -1e-8 : 1e-8) : distance;
  float denominator = focus - aperture;
  denominator = abs(denominator) < 1e-8 ? (denominator < 0.0 ? -1e-8 : 1e-8) : denominator;
  return clamp(((post.strengthControl / 5.0) * abs(distance - focus) / safeDistance * (aperture / denominator)) / 0.024, 0.0001, 0.12) * 0.3;
}

// concentric square -> disc mapping, aspect-corrected so the disc is round on screen
float2 ddDisk(float2 coordinate, float aspect) {
  float x = 2.0 * coordinate.x - 1.0, y = 2.0 * coordinate.y - 1.0, radius = y, angle;
  if (x * x > y * y) { radius = x; angle = DD_PI * 0.25 * y / x; }
  else angle = DD_PI * 0.25 * x / y + DD_PI * 0.5;
  return float2(cos(angle) / aspect, sin(angle)) * radius;
}

float4 ddDefocus(texture2d<float> scene, float2 uv, DDPost post, float aspect) {
  float4 total = float4(0.0);
  float centerCoc = ddCoc(wp_scene(scene, uv, 0.0).a, post), centerDistance = ddSceneDistance(scene, uv), totalWeight = 0.0;
  for (int row = 0; row < 8; row++) for (int column = 0; column < 8; column++) {
    float2 coordinate = uv + ddDisk((float2(float(column), float(row)) + 0.5) / 8.0, aspect) * centerCoc;
    if (any(coordinate < float2(0.0)) || any(coordinate > float2(1.0))) continue;
    float neighbourCoc = ddCoc(wp_scene(scene, coordinate, 0.0).a, post);
    float4 neighbour = float4(wp_scene(scene, coordinate, 0.9).rgb, neighbourCoc);
    float weight = ddDofWeight(scene, coordinate, centerCoc, centerDistance, neighbourCoc);
    total += neighbour * weight; totalWeight += weight;
  }
  return total / max(totalWeight, 1e-8);
}

float3 ddBloom(texture2d<float> scene, float2 uv, float aspect) {
  float2 stepUv = 0.2352941185 / 10.0 * float2(1.0, aspect);
  const float taps[7] = {1.0, 6.0, 15.0, 20.0, 15.0, 6.0, 1.0};
  float3 total = float3(0.0);
  for (int y = -3; y <= 3; y++) for (int x = -3; x <= 3; x++) {
    float weight = taps[x + 3] * taps[y + 3];
    total += max(wp_scene(scene, uv + float2(float(x), float(y)) * stepUv, 5.0).rgb, float3(0.0)) * weight;
  }
  return total / 4096.0;
}

inline float4 ddRandom4(float2 coordinate, float seed) {
  float value = sin(dot(coordinate + float2(seed), float2(12.9898, 78.233))) * 43758.5453;
  return fract(value * float4(1.0, 1.2154, 1.3453, 1.3647)) * 2.0 - 1.0;
}

float ddNoise3(float3 coordinate, float seed) {
  const float cell = 1.0 / 256.0;
  float corner[8];
  float3 grid = cell * floor(coordinate) + float3(0.5 / 256.0);
  float3 local = fract(coordinate);
  for (int x = 0; x < 2; x++) for (int y = 0; y < 2; y++) for (int z = 0; z < 2; z++) {
    float4 first = ddRandom4(grid.xy + cell * float2(float(x), float(y)), seed);
    float3 gradient = ddRandom4(float2(first.w, grid.z + cell * float(z)), seed).xyz * 4.0 - 1.0;
    corner[x * 4 + y * 2 + z] = dot(gradient, local - float3(float(x), float(y), float(z)));
  }
  float4 alongX = mix(float4(corner[0], corner[1], corner[2], corner[3]), float4(corner[4], corner[5], corner[6], corner[7]), ddQuintic(local.x));
  float2 alongY = mix(alongX.xy, alongX.zw, ddQuintic(local.y));
  return mix(alongY.x, alongY.y, ddQuintic(local.z));
}

float2 ddRotateUv(float2 coordinate, float angle, float aspect) {
  coordinate.x *= aspect;
  float c = cos(angle), s = sin(angle);
  coordinate = float2(c * coordinate.x - s * coordinate.y, s * coordinate.x + c * coordinate.y);
  coordinate.x /= aspect;
  return coordinate;
}

float3 ddAces(float3 color) {
  color = max(color, float3(0.0));
  float3 aces = float3(dot(float3(0.59719, 0.35458, 0.04823), color), dot(float3(0.076, 0.90834, 0.01566), color), dot(float3(0.0284, 0.13383, 0.83777), color));
  float3 mapped = (aces * (aces + 0.0245786) - 0.000090537) / (aces * (0.983729 * aces + 0.432951) + 0.238081);
  return clamp(float3(dot(float3(1.60475, -0.53108, -0.07367), mapped), dot(float3(-0.10208, 1.10813, -0.00605), mapped), dot(float3(-0.00327, -0.07276, 1.07602), mapped)), 0.0, 1.0);
}

// the demo's film grade, a per-channel polynomial fitted to a lut
float3 ddGradeCurve(float3 color) {
  float3 value = float3(28.2009178, -4.47737138, 20.4365427);
  value = value * color + float3(-101.437163, 13.6101229, -63.9569408);
  value = value * color + float3(136.645712, -16.442739, 79.084147);
  value = value * color + float3(-88.0052381, 9.97617983, -48.5028081);
  value = value * color + float3(29.3367147, -3.05535481, 15.0955054);
  value = value * color + float3(-4.0966274, 1.35431496, -1.50459414);
  value = value * color + float3(0.351631336, 0.0282354678, 0.293262509);
  return clamp(value * color + float3(-0.00198259751, 0.00569606752, 0.0057168624), 0.0, 1.0);
}

inline float3 ddToSrgb(float3 color) {
  return select(1.055 * pow(color, float3(1.0 / 2.4)) - 0.055, color * 12.92, color <= float3(0.0031308));
}

float3 ddGrain(float3 color, float2 uv, float seed, float2 res) {
  const float channelMix = 0.501960813999176, luminanceMix = 0.556862771511078;
  const float grainScale = 0.290196090936661, grainAmount = 0.372549027204514;
  float aspect = res.x / res.y;
  float2 frequency = res / mix(1.5, 2.5, grainScale);
  float2 nativeUv = float2(uv.x, 1.0 - uv.y);
  float3 noise = float3(ddNoise3(float3(ddRotateUv(nativeUv, seed + 1.425, aspect) * frequency, 0.0), seed),
                        ddNoise3(float3(ddRotateUv(nativeUv, seed + 3.892, aspect) * frequency, 1.0), seed),
                        ddNoise3(float3(ddRotateUv(nativeUv, seed + 5.835, aspect) * frequency, 2.0), seed));
  noise = mix(float3(noise.r), noise, channelMix);
  float luminance = mix(0.0, dot(color, float3(0.3, 0.587, 0.114)), luminanceMix);
  float reverse = clamp((luminance - 0.2) / -0.2, 0.0, 1.0);
  reverse = reverse * reverse * (3.0 - 2.0 * reverse);
  return color + noise * (1.0 - pow(reverse + luminance, 4.0)) * grainAmount * 0.1;
}

float4 wp_post(float2 uv, texture2d<float> scene, constant Uniforms& u) {
  DDSetup d = ddSetup(u);
  DDPost post = ddPostForStyle(d.style, d.amount);
  float aspect = u.res.x / u.res.y;
  float3 linear = ddDefocus(scene, uv, post, aspect).rgb + ddBloom(scene, uv, aspect) * post.bloomTint;
  float3 color = ddGrain(ddAces(linear), uv, hash11(u.seed + 4.0) * 10.0, u.res);
  return float4(ddToSrgb(ddGradeCurve(color)), 1.0);
}
