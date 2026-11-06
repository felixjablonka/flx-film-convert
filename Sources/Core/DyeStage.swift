import Foundation
import Metal
import simd

/// The dye split on the GPU: `Unmixer.dyes`, the same Newton solve per pixel
/// from the same start with the same stop, so it gives what the CPU gives (to
/// the last bits of the arithmetic), 15 or so times faster. The base comes as
/// a grid of the reference's own values, sampled bilinear: the rebate field
/// is a quartic and a dome, far smoother than the grid.
final class DyeStage {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    /// The film's spectra, per unmixer, and the last base grid, for the loupe
    /// asking again and again for parts of one frame.
    private var spectra: [ObjectIdentifier: (weight: MTLBuffer, dye: MTLBuffer)] = [:]
    private var grid: (base: BaseReference, width: Int, height: Int, texture: MTLTexture)?
    /// Rows the GPU takes at a time, so a full-size frame does not sit there
    /// whole beside its copies on the CPU.
    private static let band = 1024

    /// Laid out as `UnmixUniforms` in the kernel.
    private struct Uniforms {
        var inverse0 = SIMD4<Float>(), inverse1 = SIMD4<Float>(), inverse2 = SIMD4<Float>()
        var rows = SIMD4<Float>()
        var originX: Int32 = 0, originY: Int32 = 0
        var frameWidth: Int32 = 1, frameHeight: Int32 = 1
        var gridWidth: Int32 = 1, gridHeight: Int32 = 1
        var n: Int32 = 0, monochrome: Int32 = 0
        /// Where in the source texture this dispatch's first pixel is.
        var sourceX: Int32 = 0, sourceY: Int32 = 0, pad0: Int32 = 0, pad1: Int32 = 0
    }

    /// A frame kept on the GPU whole (private memory, out of reach of the
    /// memory compressor), for the loupe's parts of it.
    final class Resident {
        let texture: MTLTexture
        var width: Int { texture.width }
        var height: Int { texture.height }
        init(_ t: MTLTexture) { texture = t }
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PrintStage.Failure.noDevice
        }
        self.device = device
        self.queue = queue
        let options = MTLCompileOptions()
        options.mathMode = .safe                    // exp and log10 as precise as the CPU's
        let library = try device.makeLibrary(source: Self.source, options: options)
        guard let f = library.makeFunction(name: "unmix") else { throw PrintStage.Failure.missingKernel }
        pipeline = try device.makeComputePipelineState(function: f)
    }

    private func texture(_ values: [Float]?, width: Int, height: Int, writable: Bool = false) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height,
                                                         mipmapped: false)
        d.usage = writable ? [.shaderRead, .shaderWrite] : [.shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw PrintStage.Failure.allocation }
        if let values {
            values.withUnsafeBytes { raw in
                t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                          withBytes: raw.baseAddress!, bytesPerRow: width * 16)
            }
        }
        return t
    }

    private func baseGrid(_ base: BaseReference, frameWidth fw: Int, frameHeight fh: Int) throws -> (MTLTexture, Int, Int) {
        if let g = grid, g.base == base, g.width == fw, g.height == fh {
            return (g.texture, g.texture.width, g.texture.height)
        }
        // The base on a grid 512 across the whole frame, at its nodes' centres.
        let gw = min(512, fw), gh = max(2, min(fh, Int((512 * Double(fh) / Double(max(fw, 1))).rounded())))
        var values = [Float](repeating: 0, count: gw * gh * 4)
        values.withUnsafeMutableBufferPointer { o in
            let o = o
            DispatchQueue.concurrentPerform(iterations: gh) { y in
                for x in 0..<gw {
                    let v = base.log(x: (Double(x) + 0.5) / Double(gw), y: (Double(y) + 0.5) / Double(gh))
                    let i = (y * gw + x) * 4
                    o[i] = v.x; o[i + 1] = v.y; o[i + 2] = v.z
                }
            }
        }
        let t = try texture(values, width: gw, height: gh)
        grid = (base, fw, fh, t)
        return (t, gw, gh)
    }

    private func spectra(for unmixer: Unmixer) throws -> (weight: MTLBuffer, dye: MTLBuffer) {
        if let s = spectra[ObjectIdentifier(unmixer)] { return s }
        guard let w = device.makeBuffer(bytes: unmixer.weight, length: max(unmixer.weight.count, 1) * 4, options: .storageModeShared),
              let d = device.makeBuffer(bytes: unmixer.dye, length: max(unmixer.dye.count, 1) * 4, options: .storageModeShared) else {
            throw PrintStage.Failure.allocation
        }
        spectra[ObjectIdentifier(unmixer)] = (w, d)
        return (w, d)
    }

    /// The whole scan put on the GPU, a band at a time.
    func resident(_ scan: Scan) throws -> Resident {
        let w = scan.width, h = scan.height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .private
        guard let whole = device.makeTexture(descriptor: d) else { throw PrintStage.Failure.allocation }
        let rows = min(Self.band, h)
        let staging = try texture(nil, width: w, height: rows)
        var y0 = 0
        while y0 < h {
            let here = min(rows, h - y0)
            scan.pixels.withUnsafeBytes { raw in
                staging.replace(region: MTLRegionMake2D(0, 0, w, here), mipmapLevel: 0,
                                withBytes: raw.baseAddress!.advanced(by: y0 * w * 16), bytesPerRow: w * 16)
            }
            guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else {
                throw PrintStage.Failure.allocation
            }
            blit.copy(from: staging, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: w, height: here, depth: 1), to: whole, destinationSlice: 0,
                      destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: y0, z: 0))
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            y0 += here
        }
        return Resident(whole)
    }

    /// The dye amounts of the part `box` of a resident frame.
    func negative(of frame: Resident, box: (x: Int, y: Int, width: Int, height: Int), base: BaseReference,
                  unmixer: Unmixer) throws -> [Float] {
        let (gridTexture, gw, gh) = try baseGrid(base, frameWidth: frame.width, frameHeight: frame.height)
        let (weights, dyes) = try spectra(for: unmixer)
        var u = uniforms(unmixer, frameWidth: frame.width, frameHeight: frame.height, gridWidth: gw, gridHeight: gh)
        u.originX = Int32(box.x); u.originY = Int32(box.y)
        u.sourceX = Int32(box.x); u.sourceY = Int32(box.y)
        let out = try texture(nil, width: box.width, height: box.height, writable: true)
        guard let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else {
            throw PrintStage.Failure.allocation
        }
        e.setComputePipelineState(pipeline)
        e.setTexture(frame.texture, index: 0)
        e.setTexture(gridTexture, index: 1)
        e.setTexture(out, index: 2)
        e.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        e.setBuffer(weights, offset: 0, index: 1)
        e.setBuffer(dyes, offset: 0, index: 2)
        let tw = pipeline.threadExecutionWidth, th = max(pipeline.maxTotalThreadsPerThreadgroup / tw, 1)
        e.dispatchThreads(MTLSize(width: box.width, height: box.height, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        e.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var result = [Float](repeating: 0, count: box.width * box.height * 4)
        result.withUnsafeMutableBytes { raw in
            out.getBytes(raw.baseAddress!, bytesPerRow: box.width * 16,
                         from: MTLRegionMake2D(0, 0, box.width, box.height), mipmapLevel: 0)
        }
        return result
    }

    private func uniforms(_ unmixer: Unmixer, frameWidth fw: Int, frameHeight fh: Int,
                          gridWidth gw: Int, gridHeight gh: Int) -> Uniforms {
        var u = Uniforms()
        let inv = unmixer.seenInverse
        u.inverse0 = SIMD4(inv.columns.0, 0); u.inverse1 = SIMD4(inv.columns.1, 0); u.inverse2 = SIMD4(inv.columns.2, 0)
        let s = unmixer.seen
        let rows = (0..<3).map { c in s[0][c] + s[1][c] + s[2][c] }
        u.rows = SIMD4(rows[0], rows[1], rows[2], 0)
        u.frameWidth = Int32(fw); u.frameHeight = Int32(fh)
        u.gridWidth = Int32(gw); u.gridHeight = Int32(gh)
        u.n = Int32(unmixer.n)
        u.monochrome = unmixer.film.isMonochrome ? 1 : 0
        return u
    }

    /// The scan's dye amounts (RGBA32F), as `Unmixer.negative` gives them.
    func negative(of scan: Scan, base: BaseReference, unmixer: Unmixer,
                  part: (origin: CGPoint, frameWidth: Int, frameHeight: Int)? = nil) throws -> [Float] {
        let w = scan.width, h = scan.height
        let fw = part?.frameWidth ?? w, fh = part?.frameHeight ?? h
        let (gridTexture, gw, gh) = try baseGrid(base, frameWidth: fw, frameHeight: fh)
        let (weights, dyes) = try spectra(for: unmixer)
        var u = uniforms(unmixer, frameWidth: fw, frameHeight: fh, gridWidth: gw, gridHeight: gh)

        var result = [Float](repeating: 0, count: w * h * 4)
        let rowsPerBand = min(Self.band, h)
        let src = try texture(nil, width: w, height: rowsPerBand)
        let out = try texture(nil, width: w, height: rowsPerBand, writable: true)
        var y0 = 0
        while y0 < h {
            let rowsHere = min(rowsPerBand, h - y0)
            scan.pixels.withUnsafeBytes { raw in
                src.replace(region: MTLRegionMake2D(0, 0, w, rowsHere), mipmapLevel: 0,
                            withBytes: raw.baseAddress!.advanced(by: y0 * w * 16), bytesPerRow: w * 16)
            }
            u.originX = Int32(part?.origin.x ?? 0)
            u.originY = Int32(part?.origin.y ?? 0) + Int32(y0)
            guard let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else {
                throw PrintStage.Failure.allocation
            }
            e.setComputePipelineState(pipeline)
            e.setTexture(src, index: 0)
            e.setTexture(gridTexture, index: 1)
            e.setTexture(out, index: 2)
            e.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            e.setBuffer(weights, offset: 0, index: 1)
            e.setBuffer(dyes, offset: 0, index: 2)
            let tw = pipeline.threadExecutionWidth, th = max(pipeline.maxTotalThreadsPerThreadgroup / tw, 1)
            e.dispatchThreads(MTLSize(width: w, height: rowsHere, depth: 1),
                              threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            e.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            result.withUnsafeMutableBytes { raw in
                out.getBytes(raw.baseAddress!.advanced(by: y0 * w * 16), bytesPerRow: w * 16,
                             from: MTLRegionMake2D(0, 0, w, rowsHere), mipmapLevel: 0)
            }
            y0 += rowsHere
        }
        return result
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct UnmixUniforms {
        float4 inverse0, inverse1, inverse2, rows;
        int originX, originY, frameWidth, frameHeight;
        int gridWidth, gridHeight, n, monochrome;
        int sourceX, sourceY, pad0, pad1;
    };

    inline float3x3 inverse3(float3x3 m) {
        float3 a = m[0], b = m[1], c = m[2];
        float3 r0 = cross(b, c), r1 = cross(c, a), r2 = cross(a, b);
        float det = dot(a, r0);
        return transpose(float3x3(r0, r1, r2)) * (1.0f / det);
    }

    kernel void unmix(texture2d<float, access::read> scan [[texture(0)]],
                      texture2d<float, access::read> base [[texture(1)]],
                      texture2d<float, access::write> out [[texture(2)]],
                      constant UnmixUniforms &u [[buffer(0)]],
                      constant float *weight [[buffer(1)]],
                      constant float *dye [[buffer(2)]],
                      uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        // Where the pixel lies in the whole frame (a band of rows, or the
        // loupe's part, starts at the origin), and the base there.
        float2 f = (float2(int2(gid) + int2(u.originX, u.originY)) + 0.5f) / float2(u.frameWidth, u.frameHeight);
        float2 g = clamp(f * float2(u.gridWidth, u.gridHeight) - 0.5f, float2(0.0f),
                         float2(u.gridWidth - 1, u.gridHeight - 1));
        int2 g0 = max(min(int2(g), int2(u.gridWidth - 2, u.gridHeight - 2)), int2(0));
        int2 g1 = min(g0 + 1, int2(u.gridWidth - 1, u.gridHeight - 1));
        float2 gt = g - float2(g0);
        float3 b = mix(mix(base.read(uint2(g0)).rgb, base.read(uint2(g1.x, g0.y)).rgb, gt.x),
                       mix(base.read(uint2(g0.x, g1.y)).rgb, base.read(uint2(g1)).rgb, gt.x), gt.y);
        float3 c = scan.read(gid + uint2(u.sourceX, u.sourceY)).rgb;
        float3 d = clamp(b - log10(max(c, float3(1e-6f))), -0.5f, 4.0f);
        if (u.monochrome != 0) {
            float x = (d.x / u.rows.x + d.y / u.rows.y + d.z / u.rows.z) / 3.0f;
            out.write(float4(x, x, x, 1.0f), gid);
            return;
        }
        // Unmixer.dyes: Newton on the channels' log brightness, from the
        // linear guess, eight steps at most.
        int n = u.n;
        float3x3 inv = float3x3(u.inverse0.xyz, u.inverse1.xyz, u.inverse2.xyz);
        float3 x = inv * d;
        for (int it = 0; it < 8; it++) {
            float3 gsum = float3(0.0f), h0 = float3(0.0f), h1 = float3(0.0f), h2 = float3(0.0f);
            for (int i = 0; i < n; i++) {
                float d0 = dye[i], d1 = dye[n + i], d2 = dye[2 * n + i];
                float e = exp(-2.302585f * (x.x * d0 + x.y * d1 + x.z * d2));
                float3 we = float3(weight[i], weight[n + i], weight[2 * n + i]) * e;
                gsum += we; h0 += we * d0; h1 += we * d1; h2 += we * d2;
            }
            gsum = max(gsum, float3(1e-8f));
            float3x3 hm = float3x3(h0 / gsum, h1 / gsum, h2 / gsum);
            float3 step = inverse3(hm) * (log10(gsum) + d);
            x = clamp(x + step, -0.5f, 4.0f);
            if (length(step) < 1e-5f) break;
        }
        out.write(float4(x, 1.0f), gid);
    }
    """
}
