import Foundation
import Metal
import simd

/// What the print's detail controls are set to: NegPy's scanner-side
/// sharpening and CLAHE, on the finished print. Both work on its lightness
/// (CIE L*) alone and scale the pixel's RGB to match, so they move tone the way
/// a very fine dodge or burn would and leave the film's colour as it is.
struct DetailSettings: Equatable {
    /// Unsharp mask: how much of the detail (L* minus its blur) is added again;
    /// 1 doubles it.
    var sharpness: Double = 0
    /// The blur's sigma, in pixels of the scan at full size, so the preview
    /// and the export sharpen the same detail (a fitted preview can show
    /// little of it: the loupe shows it at 100%).
    var radius: Double = 1
    /// 0...1: leaves flat areas (sky, skin, grain) unsharpened, from the
    /// local gradient of L*.
    var masking: Double = 0
    /// CLAHE, 0...1: equalises L* in an 8 x 8 grid of tiles over the print,
    /// each tile's histogram clipped at 2.5 x this times its mean before it
    /// is accumulated, the result blended in by this much (as NegPy does).
    var localContrast: Double = 0

    var isActive: Bool { sharpness > 0 || localContrast > 0 }
}

/// The detail controls on the GPU, after `print_and_scan` and before Bloom &
/// Glow, on the linear print in its output colour space.
final class DetailStage {
    static let grid = 8, bins = 256

    private let device: MTLDevice
    private let lightness: MTLComputePipelineState
    private let blur: MTLComputePipelineState
    private let histogram: MTLComputePipelineState
    private let cumulate: MTLComputePipelineState
    private let apply: MTLComputePipelineState

    /// Laid out as `DetailUniforms` in the kernels.
    private struct Uniforms {
        var luma = SIMD4<Float>(0.2126, 0.7152, 0.0722, 0)
        var strength: Float = 0
        var clip: Float = 0
        var amount: Float = 0
        var maskThreshold: Float = 0
        var originX: Int32 = 0, originY: Int32 = 0
        var frameWidth: Int32 = 1, frameHeight: Int32 = 1
        var clahe: Int32 = 0, sharpen: Int32 = 0
        var pad0: Int32 = 0, pad1: Int32 = 0
    }

    init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.source, options: nil)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw PrintStage.Failure.missingKernel }
            return try device.makeComputePipelineState(function: f)
        }
        lightness = try pipeline("detail_lightness")
        blur = try pipeline("detail_blur")
        histogram = try pipeline("clahe_histogram")
        cumulate = try pipeline("clahe_cdf")
        apply = try pipeline("detail_apply")
    }

    /// Luminance from the output space's linear RGB: the middle row of its
    /// RGB-to-XYZ matrix, from the engine's own tables.
    static func luma(outputColorSpace: String) -> SIMD3<Float> {
        let white = outputColorSpace == "ProPhoto RGB" ? "D50" : "D65"
        let m = PackLibrary.shared.shared_.xyzToRGBMatrix(viewing: white, output: outputColorSpace).inverse
        let row = SIMD3(m.columns.0.y, m.columns.1.y, m.columns.2.y)
        let sum = row.x + row.y + row.z
        return sum > 0.5 ? row / sum : SIMD3(0.2126, 0.7152, 0.0722)
    }

    /// The tiles' equalising curves, 64 x 256, as a render computed them, for
    /// a render of part of the print (the loupe) to use the whole print's.
    struct Curves { var values: [Float] }

    /// Encodes the detail controls on `printed` into `cb`, returning the
    /// texture that holds the result. `scale` is this render's pixels per
    /// pixel of the full-size scan. `origin` and `frame` place this render in
    /// the whole print, in this render's pixels, for the CLAHE grid; `curves`
    /// given are used instead of this render's own (which `measured` then
    /// returns, once `cb` has completed).
    func encode(_ printed: MTLTexture, cb: MTLCommandBuffer, settings: DetailSettings, scale: Double,
                outputColorSpace: String, origin: SIMD2<Int32> = .zero, frame: SIMD2<Int32>? = nil,
                curves: Curves? = nil) throws -> (texture: MTLTexture, measured: () -> Curves?) {
        let w = printed.width, h = printed.height
        func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw PrintStage.Failure.allocation }
            return t
        }
        var u = Uniforms()
        let luma = Self.luma(outputColorSpace: outputColorSpace)
        u.luma = SIMD4(luma, 0)
        u.strength = Float(min(max(settings.localContrast, 0), 1))
        u.clip = u.strength * 2.5
        u.amount = Float(max(settings.sharpness, 0))
        u.maskThreshold = Float(10 * min(max(settings.masking, 0), 1))
        u.originX = origin.x; u.originY = origin.y
        let f = frame ?? SIMD2(Int32(w), Int32(h))
        u.frameWidth = max(f.x, 1); u.frameHeight = max(f.y, 1)
        u.clahe = settings.localContrast > 0 ? 1 : 0
        u.sharpen = settings.sharpness > 0 ? 1 : 0

        let l = try texture(.r32Float)
        let out = try texture(.rgba32Float)
        guard let e = cb.makeComputeCommandEncoder() else { throw PrintStage.Failure.allocation }
        e.setTexture(printed, index: 0)
        e.setTexture(l, index: 1)
        e.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        dispatch(e, lightness, w, h)

        // Sharpening's blur: a separable Gaussian of L*, its sigma in this
        // render's pixels.
        var blurred = l
        if u.sharpen != 0 {
            let sigma = max(settings.radius * scale, 0.05)
            let r = max(1, min(64, Int((2.5 * sigma).rounded(.up))))
            var weights = (-r...r).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
            let total = weights.reduce(0, +)
            weights = weights.map { $0 / total }
            guard let wb = device.makeBuffer(bytes: weights, length: weights.count * 4, options: .storageModeShared) else {
                throw PrintStage.Failure.allocation
            }
            let across = try texture(.r32Float), both = try texture(.r32Float)
            var radius = Int32(r)
            for (src, dst, horizontal) in [(l, across, Int32(1)), (across, both, Int32(0))] {
                var hz = horizontal
                e.setTexture(src, index: 0)
                e.setTexture(dst, index: 1)
                e.setBuffer(wb, offset: 0, index: 0)
                e.setBytes(&radius, length: 4, index: 1)
                e.setBytes(&hz, length: 4, index: 2)
                dispatch(e, blur, w, h)
            }
            blurred = both
        }

        // CLAHE: each tile's histogram of L*, clipped and accumulated.
        let count = Self.grid * Self.grid * Self.bins
        guard let curveBuffer = device.makeBuffer(length: count * 4, options: .storageModeShared) else {
            throw PrintStage.Failure.allocation
        }
        var own = false
        if u.clahe != 0 {
            if let curves, curves.values.count == count {
                curves.values.withUnsafeBytes { curveBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: count * 4) }
            } else {
                guard let hist = device.makeBuffer(length: count * 4, options: .storageModeShared) else {
                    throw PrintStage.Failure.allocation
                }
                memset(hist.contents(), 0, count * 4)
                e.setTexture(l, index: 0)
                e.setBuffer(hist, offset: 0, index: 0)
                e.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                dispatch(e, histogram, w, h)
                e.setComputePipelineState(cumulate)
                e.setBuffer(hist, offset: 0, index: 0)
                e.setBuffer(curveBuffer, offset: 0, index: 1)
                e.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
                e.dispatchThreads(MTLSize(width: Self.grid * Self.grid, height: 1, depth: 1),
                                  threadsPerThreadgroup: MTLSize(width: Self.grid * Self.grid, height: 1, depth: 1))
                own = true
            }
        }
        e.setTexture(printed, index: 0)
        e.setTexture(l, index: 1)
        e.setTexture(blurred, index: 2)
        e.setTexture(out, index: 3)
        e.setBuffer(curveBuffer, offset: 0, index: 0)
        e.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        dispatch(e, apply, w, h)
        e.endEncoding()
        let measured: () -> Curves? = {
            guard own else { return nil }
            let p = curveBuffer.contents().bindMemory(to: Float.self, capacity: count)
            return Curves(values: Array(UnsafeBufferPointer(start: p, count: count)))
        }
        return (out, measured)
    }

    private func dispatch(_ e: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, _ width: Int, _ height: Int) {
        e.setComputePipelineState(p)
        let w = p.threadExecutionWidth, h = max(p.maxTotalThreadsPerThreadgroup / w, 1)
        e.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct DetailUniforms {
        float4 luma;
        float strength, clip, amount, maskThreshold;
        int originX, originY, frameWidth, frameHeight;
        int clahe, sharpen, pad0, pad1;
    };

    constant int GRID = 8;
    constant int BINS = 256;

    inline float lstar(float y) {
        y = max(y, 0.0f);
        float f = y > 0.008856f ? pow(y, 1.0f / 3.0f) : 7.787f * y + 16.0f / 116.0f;
        return 116.0f * f - 16.0f;
    }

    inline float luminance(float l) {
        float f = (l + 16.0f) / 116.0f;
        return f > 0.206893f ? f * f * f : (f - 16.0f / 116.0f) / 7.787f;
    }

    kernel void detail_lightness(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant DetailUniforms &u [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float3 c = max(src.read(gid).rgb, 0.0f);
        dst.write(float4(lstar(dot(c, u.luma.rgb))), gid);
    }

    kernel void detail_blur(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant float *weights [[buffer(0)]],
                            constant int &radius [[buffer(1)]],
                            constant int &horizontal [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
        int w = dst.get_width(), h = dst.get_height();
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        float sum = 0.0f;
        for (int i = -radius; i <= radius; i++) {
            int2 p = horizontal != 0 ? int2(clamp(int(gid.x) + i, 0, w - 1), int(gid.y))
                                     : int2(int(gid.x), clamp(int(gid.y) + i, 0, h - 1));
            sum += weights[i + radius] * src.read(uint2(p)).r;
        }
        dst.write(float4(sum), gid);
    }

    inline int2 tileOf(uint2 gid, constant DetailUniforms &u) {
        float2 p = float2(int2(gid) + int2(u.originX, u.originY)) + 0.5f;
        return clamp(int2(p / float2(u.frameWidth, u.frameHeight) * float(GRID)), int2(0), int2(GRID - 1));
    }

    kernel void clahe_histogram(texture2d<float, access::read> l [[texture(0)]],
                                device atomic_uint *hist [[buffer(0)]],
                                constant DetailUniforms &u [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= l.get_width() || gid.y >= l.get_height()) return;
        int2 t = tileOf(gid, u);
        int bin = clamp(int(l.read(gid).r / 100.0f * 255.0f), 0, BINS - 1);
        atomic_fetch_add_explicit(&hist[(t.y * GRID + t.x) * BINS + bin], 1u, memory_order_relaxed);
    }

    // One thread a tile: the histogram clipped at clip x its mean, what was
    // clipped spread evenly over all bins, then accumulated to 0...1.
    kernel void clahe_cdf(device const uint *hist [[buffer(0)]],
                          device float *cdf [[buffer(1)]],
                          constant DetailUniforms &u [[buffer(2)]],
                          uint t [[thread_position_in_grid]]) {
        if (t >= uint(GRID * GRID)) return;
        device const uint *h = hist + t * BINS;
        uint total = 0;
        for (int b = 0; b < BINS; b++) total += h[b];
        uint limit = max(1u, uint(u.clip * float(total) / float(BINS)));
        uint excess = 0;
        for (int b = 0; b < BINS; b++) excess += h[b] > limit ? h[b] - limit : 0u;
        uint inc = excess / BINS, rem = excess % BINS;
        float run = 0.0f, inv = 1.0f / float(max(total, 1u));
        for (int b = 0; b < BINS; b++) {
            run += float(min(h[b], limit) + inc + (uint(b) < rem ? 1u : 0u));
            cdf[t * BINS + b] = run * inv;
        }
    }

    kernel void detail_apply(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::read> lt [[texture(1)]],
                             texture2d<float, access::read> blurred [[texture(2)]],
                             texture2d<float, access::write> dst [[texture(3)]],
                             constant float *cdf [[buffer(0)]],
                             constant DetailUniforms &u [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        int w = dst.get_width(), h = dst.get_height();
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        float3 c = src.read(gid).rgb;
        float l = lt.read(gid).r;
        float out = l;
        if (u.clahe != 0) {
            // The four nearest tiles' curves, blended by smoothstep.
            float2 p = float2(int2(gid) + int2(u.originX, u.originY)) + 0.5f;
            float2 tp = p / float2(u.frameWidth, u.frameHeight) * float(GRID) - 0.5f;
            float2 tf = floor(tp), r = tp - tf, s = r * r * (3.0f - 2.0f * r);
            int2 lo = clamp(int2(tf), int2(0), int2(GRID - 1)), hi = clamp(int2(tf) + 1, int2(0), int2(GRID - 1));
            int bin = clamp(int(l / 100.0f * 255.0f), 0, BINS - 1);
            float a = cdf[(lo.y * GRID + lo.x) * BINS + bin], b = cdf[(lo.y * GRID + hi.x) * BINS + bin];
            float d = cdf[(hi.y * GRID + lo.x) * BINS + bin], e = cdf[(hi.y * GRID + hi.x) * BINS + bin];
            float v = mix(mix(a, b, s.x), mix(d, e, s.x), s.y);
            out = l + (v * 100.0f - l) * u.strength;
        }
        if (u.sharpen != 0) {
            float lmin = l, lmax = l;
            float n[9];
            for (int j = -1; j <= 1; j++) {
                for (int i = -1; i <= 1; i++) {
                    float v = lt.read(uint2(clamp(int2(gid) + int2(i, j), int2(0), int2(w - 1, h - 1)))).r;
                    n[(j + 1) * 3 + i + 1] = v;
                    lmin = min(lmin, v); lmax = max(lmax, v);
                }
            }
            float m = 1.0f;
            if (u.maskThreshold > 0.0f) {
                float gx = (n[2] + 2.0f * n[5] + n[8] - n[0] - 2.0f * n[3] - n[6]) / 8.0f;
                float gy = (n[6] + 2.0f * n[7] + n[8] - n[0] - 2.0f * n[1] - n[2]) / 8.0f;
                m = smoothstep(0.5f * u.maskThreshold, u.maskThreshold, length(float2(gx, gy)));
            }
            // No halos: the sharpened value stays within the 3 x 3 range, a
            // little tighter above, where L* sharpening shows light rims.
            float sharp = clamp(l + (l - blurred.read(gid).r) * u.amount * m, lmin - 2.0f, lmax + 1.0f);
            out += sharp - l;
        }
        float y = dot(max(c, 0.0f), u.luma.rgb);
        float k = y > 1e-6f ? luminance(clamp(out, 0.0f, 120.0f)) / y : 1.0f;
        dst.write(float4(max(c * k, 0.0f), 1.0f), gid);
    }
    """
}
