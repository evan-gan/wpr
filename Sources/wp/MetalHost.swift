import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct Uniforms {
  var res: SIMD2<Float>
  var seed: Float
  var time: Float
}

enum MetalHost {
  // prepended to every module shader: entry points, uniforms, and a small helper library
  static let header = """
  #include <metal_stdlib>
  using namespace metal;

  struct Uniforms { float2 res; float seed; float time; };
  struct VOut { float4 pos [[position]]; float2 uv; };

  vertex VOut wp_vertex(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    VOut o; o.pos = float4(p[vid], 0, 1); o.uv = (p[vid] + 1.0) * 0.5; return o;
  }

  inline uint wp_pcg(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
  }
  inline float hash11(float x) { return float(wp_pcg(as_type<uint>(x))) / 4294967295.0; }
  inline float hash21(float2 p) {
    uint h = wp_pcg(as_type<uint>(p.x) ^ wp_pcg(as_type<uint>(p.y)));
    return float(h) / 4294967295.0;
  }
  inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1,0)), c = hash21(i + float2(0,1)), d = hash21(i + float2(1,1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
  }
  inline float fbm(float2 p, int octaves) {
    float s = 0.0, a = 0.5;
    float2x2 m = float2x2(1.6, 1.2, -1.2, 1.6);
    for (int i = 0; i < octaves; i++) { s += a * vnoise(p); p = m * p; a *= 0.5; }
    return s;
  }
  // fbm where octaves finer than the pixel footprint fade out instead of aliasing
  inline float fbm_lod(float2 p, int octaves, float footprint) {
    float s = 0.0, a = 0.5, freq = 1.0;
    float2x2 m = float2x2(1.6, 1.2, -1.2, 1.6);
    for (int i = 0; i < octaves; i++) {
      float w = 1.0 - smoothstep(0.15, 0.4, footprint * freq);
      s += a * w * vnoise(p);
      p = m * p; a *= 0.5; freq *= 2.0;
    }
    return s;
  }
  inline float3 hsv2rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(1.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
  }

  // a module may add a second pass by defining
  //   float4 wp_post(float2 uv, texture2d<float> scene, constant Uniforms& u)
  // the first pass then renders to an rgba16Float texture (hdr colour, alpha free for depth or
  // anything else), gets mipmaps, and wp_post writes the final image. wp_scene samples it in the
  // same uv space; the lod form reads a coarser level, i.e. an area average around uv
  constexpr sampler wp_sampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
  inline float4 wp_scene(texture2d<float> t, float2 uv) { return t.sample(wp_sampler, float2(uv.x, 1.0 - uv.y)); }
  inline float4 wp_scene(texture2d<float> t, float2 uv, float lod) { return t.sample(wp_sampler, float2(uv.x, 1.0 - uv.y), level(lod)); }

  """

  static let footer = """

  fragment float4 wp_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    return wp_main(in.uv, u);
  }
  """

  static let postFooter = """

  fragment float4 wp_fragment_post(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                   texture2d<float> scene [[texture(0)]]) {
    return wp_post(in.uv, scene, u);
  }
  """

  // `--set name=value` becomes `#define WP_PARAM_name value` ahead of the module source; a module
  // opts in with `#ifndef WP_PARAM_name / #define WP_PARAM_name <default> / #endif`
  static func render(source: String, width: Int, height: Int, seed: UInt32, params: [String] = []) throws -> CGImage {
    guard let dev = MTLCreateSystemDefaultDevice() else { throw WPError("no Metal device") }

    var defines = ""
    for p in params {
      guard let eq = p.firstIndex(of: "=") else { throw WPError("bad --set '\(p)', want name=value") }
      let name = p[..<eq], value = p[p.index(after: eq)...]
      guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), Double(value) != nil else {
        throw WPError("metal params are numeric: --set \(name)=<number>")
      }
      defines += "#define WP_PARAM_\(name) \(value)\n"
    }

    let hasPost = source.contains("wp_post(")
    let lib: MTLLibrary
    do {
      lib = try dev.makeLibrary(source: header + defines + source + footer + (hasPost ? postFooter : ""), options: nil)
    } catch {
      throw WPError("shader compile failed:\n\(error.localizedDescription)")
    }

    func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
      let pd = MTLRenderPipelineDescriptor()
      pd.vertexFunction = lib.makeFunction(name: "wp_vertex")
      pd.fragmentFunction = lib.makeFunction(name: fragment)
      pd.colorAttachments[0].pixelFormat = format
      return try dev.makeRenderPipelineState(descriptor: pd)
    }
    func texture(_ format: MTLPixelFormat, _ storage: MTLStorageMode, mipmapped: Bool = false) throws -> MTLTexture {
      let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: mipmapped)
      td.usage = [.renderTarget, .shaderRead]
      td.storageMode = storage
      guard let t = dev.makeTexture(descriptor: td) else { throw WPError("Metal setup failed") }
      return t
    }

    guard let queue = dev.makeCommandQueue(), let cb = queue.makeCommandBuffer() else { throw WPError("Metal setup failed") }
    let u = Uniforms(res: SIMD2(Float(width), Float(height)), seed: Float(seed), time: 0)
    func pass(_ pso: MTLRenderPipelineState, into target: MTLTexture, reading input: MTLTexture?) throws {
      let rp = MTLRenderPassDescriptor()
      rp.colorAttachments[0].texture = target
      rp.colorAttachments[0].loadAction = .clear
      rp.colorAttachments[0].storeAction = .store
      guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { throw WPError("no encoder") }
      enc.setRenderPipelineState(pso)
      withUnsafeBytes(of: u) { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
      if let input { enc.setFragmentTexture(input, index: 0) }
      enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      enc.endEncoding()
    }

    let tex = try texture(.bgra8Unorm, .shared)
    if hasPost {
      // the first pass keeps hdr colour plus whatever the module puts in alpha; the second reads
      // it, with mipmaps so a post effect can take area averages instead of point samples
      let scene = try texture(.rgba16Float, .private, mipmapped: true)
      try pass(try pipeline("wp_fragment", .rgba16Float), into: scene, reading: nil)
      guard let blit = cb.makeBlitCommandEncoder() else { throw WPError("no blit encoder") }
      blit.generateMipmaps(for: scene)
      blit.endEncoding()
      try pass(try pipeline("wp_fragment_post", .bgra8Unorm), into: tex, reading: scene)
    } else {
      try pass(try pipeline("wp_fragment", .bgra8Unorm), into: tex, reading: nil)
    }
    cb.commit()
    cb.waitUntilCompleted()
    if let err = cb.error { throw WPError("GPU error: \(err.localizedDescription)") }

    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    tex.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
          let img = ctx.makeImage() else { throw WPError("couldn't build CGImage") }
    return img
  }

  static func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw WPError("can't create \(url.path)")
    }
    CGImageDestinationAddImage(dst, image, nil)
    guard CGImageDestinationFinalize(dst) else { throw WPError("png write failed: \(url.path)") }
  }
}
