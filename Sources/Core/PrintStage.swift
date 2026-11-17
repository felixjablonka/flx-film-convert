import Foundation
import Metal
import CoreImage

/// FLX Film Lab's print stage — enlarger, paper, viewing light — run on a
/// negative given as dye densities. FLX Film Lab's `Renderer` develops its
/// negative from a picture; here the negative is a scan's, so only the print
/// half of `Renderer.render` runs, the way it runs there:
///
/// - the negative is turned, levelled and cropped first (`apply_geometry`,
///   step 2d), as the easel and the trimmer shape a print;
/// - `print_and_scan` prints it, with the dodge-and-burn masks drawn on the
///   frame and found through the shape (spectral tables, tone LUT, tone shift
///   and uniforms from `RenderSetupBuilder`);
/// - the detail controls (sharpening and CLAHE, `DetailStage`) work on the
///   print's lightness;
/// - Bloom & Glow is laid on the finished print in linear light (step 3c);
/// - the curves (`PrintCurves`) come last, on the print as its file encodes
///   it, and the preview measures the histogram before and after them
///   (step 3d), with FLX Film Lab's `apply_curves` and `histogram_rgb`.
final class PrintStage {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let printAndScan: MTLComputePipelineState
    private let applyGeometry: MTLComputePipelineState
    private let encodeDisplay: MTLComputePipelineState
    private let applyCurves: MTLComputePipelineState
    private let histogramRGB: MTLComputePipelineState
    private let detailStage: DetailStage
    /// The curves' table, sampled again only when the curves change.
    private var curveTable: (curves: PrintCurves, buffer: MTLBuffer)?
    /// Two histograms' bins, kept from one render to the next.
    private var histogramBuffers: [MTLBuffer] = []
    private var effectsContext: CIContext?
    private static let effectsSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    enum Failure: Error { case noDevice, missingKernel, allocation }

    struct Output {
        var pixels: [Float]       // RGBA32F, linear, the recipe's output space; empty for display
        /// For the screen: RGBA8, premultiplied, the sRGB transfer function
        /// (`encode_display`), the corners outside a levelled frame clear.
        var display: [UInt8]?
        var width: Int
        var height: Int
        /// Where each pixel of the print comes from in the frame, and back.
        var map: GeometryMap
        /// The CLAHE tiles' curves this print measured, for a render of part
        /// of it to share.
        var curves: DetailStage.Curves?
        /// The print's histogram, when asked for: the finished print's, and
        /// the one its point curves were given.
        var histogram: PrintHistogram?
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.noDevice
        }
        self.device = device
        self.queue = queue
        let options = MTLCompileOptions()
        options.mathMode = .fast                     // as Renderer compiles it
        // Compiled ahead by build.sh where Xcode's Metal compiler is installed
        // (FLX Film Lab's `ShaderLibrary`: the app's bundle, or the folder the
        // tools run in), else compiled here from the source.
        let library = try ShaderLibrary.make("flx", device: device, sourcePath: "FLXFilmLab/Resources/Shaders/flx.metal",
                                             options: options) { try PackLibrary.shared.shaderSource() }
        func pipeline(_ name: String, constants: MTLFunctionConstantValues? = nil) throws -> MTLComputePipelineState {
            let f = try constants.map { try library.makeFunction(name: name, constantValues: $0) } ?? library.makeFunction(name: name)
            guard let f else { throw Failure.missingKernel }
            return try device.makeComputePipelineState(function: f)
        }
        // print_and_scan's plain variant: FLX Film Lab's preview keeps the
        // print's exposure between renders (function constants 0 and 1), which
        // a function with constants must be told even when off.
        let plain = MTLFunctionConstantValues()
        var off = false
        plain.setConstantValue(&off, type: .bool, index: 0)
        plain.setConstantValue(&off, type: .bool, index: 1)
        printAndScan = try pipeline("print_and_scan", constants: plain)
        applyGeometry = try pipeline("apply_geometry")
        encodeDisplay = try pipeline("encode_display")
        applyCurves = try pipeline("apply_curves")
        histogramRGB = try pipeline("histogram_rgb")
        detailStage = try DetailStage(device: device)
    }

    private func texture(_ values: [Float], width: Int, height: Int,
                         format: MTLPixelFormat = .rgba32Float, writable: Bool = false) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                         mipmapped: false)
        d.usage = writable ? [.shaderRead, .shaderWrite] : [.shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw Failure.allocation }
        let bytesPerPixel = format == .rg32Float ? 8 : 16
        if !values.isEmpty {
            values.withUnsafeBytes { raw in
                t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                          withBytes: raw.baseAddress!, bytesPerRow: width * bytesPerPixel)
            }
        }
        return t
    }

    private func buffer(_ values: [Float]) throws -> MTLBuffer {
        guard let b = device.makeBuffer(bytes: values, length: values.count * MemoryLayout<Float>.size,
                                        options: .storageModeShared) else { throw Failure.allocation }
        return b
    }

    private func dispatch(_ e: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, width: Int, height: Int) {
        e.setComputePipelineState(p)
        let w = p.threadExecutionWidth, h = max(p.maxTotalThreadsPerThreadgroup / w, 1)
        e.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    private func readback(_ t: MTLTexture) -> [Float] {
        var out = [Float](repeating: 0, count: t.width * t.height * 4)
        out.withUnsafeMutableBytes { raw in
            t.getBytes(raw.baseAddress!, bytesPerRow: t.width * 16,
                       from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        }
        return out
    }

    /// Prints `cmy` (RGBA32F, dye densities above the film's base, the frame
    /// as scanned) shaped by `geometry`. `wholeFrame` prints the whole turned,
    /// levelled frame instead of the crop, for editing the crop; the corners
    /// levelling leaves empty come out as `outside`, or clear for display.
    /// `forDisplay` encodes the print for the screen on the GPU and reads back
    /// a quarter of the data, as FLX Film Lab's preview does. `detailScale` is
    /// this negative's pixels per pixel of the scan at full size. `histogram`
    /// measures the print's histogram (the preview's).
    func print(negative cmy: [Float], width: Int, height: Int, setup: RenderSetup, recipe: Recipe,
               geometry: FrameGeometry, wholeFrame: Bool = false, forDisplay: Bool = false,
               detail: DetailSettings = DetailSettings(), detailScale: Double = 1, histogram: Bool = false,
               outside: SIMD3<Float> = SIMD3(repeating: 0.03)) throws -> Output {
        let map = GeometryMap(geometry, sourceWidth: width, sourceHeight: height, wholeFrame: wholeFrame)
        let shape = GeometryUniforms(map)
        let masks = recipe.masks.filter { $0.enabled }
        let maskMap = masks.isEmpty ? nil : MaskRasterizer.rasterize(masks: masks, width: width, height: height)
        var out = try render(cmy, width: width, height: height, resample: shape, maskShape: shape,
                             outputWidth: map.outputWidth, outputHeight: map.outputHeight, maskMap: maskMap,
                             setup: setup, recipe: recipe, glowLongEdge: max(width, height),
                             detail: detail, detailScale: detailScale, origin: .zero, frame: nil, curves: nil,
                             forDisplay: forDisplay, coverage: wholeFrame && !map.isIdentity, histogram: histogram)
        if !forDisplay, wholeFrame && geometry.straighten != 0 { mark(&out.pixels, map: map, outside: outside) }
        return Output(pixels: out.pixels, display: out.display, width: map.outputWidth, height: map.outputHeight,
                      map: map, curves: out.curves, histogram: out.histogram)
    }

    /// Part of a print, for the loupe: the pixels `region` of the print of a
    /// `fullWidth` x `fullHeight` frame shaped by `geometry`, printed from the
    /// part of its negative `cmy` holds (`sourceOrigin` on, `width` x
    /// `height`). The masks are found on the whole frame as in a whole print,
    /// and CLAHE uses the whole print's `curves`, so the part looks as it
    /// does in the whole. Encoded for the screen.
    func printRegion(negative cmy: [Float], width: Int, height: Int, sourceOrigin: CGPoint,
                     fullWidth: Int, fullHeight: Int, region: CGRect, setup: RenderSetup, recipe: Recipe,
                     geometry: FrameGeometry, wholeFrame: Bool, detail: DetailSettings,
                     curves: DetailStage.Curves?) throws -> (display: [UInt8], width: Int, height: Int) {
        let map = GeometryMap(geometry, sourceWidth: fullWidth, sourceHeight: fullHeight, wholeFrame: wholeFrame)
        let t = map.outputToSource
        // From a pixel of the region to the frame, and to the part held.
        let toFrame = CGAffineTransform(translationX: region.minX, y: region.minY).concatenating(t)
        var maskShape = GeometryUniforms()
        maskShape.column0 = SIMD2(Float(toFrame.a), Float(toFrame.b))
        maskShape.column1 = SIMD2(Float(toFrame.c), Float(toFrame.d))
        maskShape.offset = SIMD2(Float(toFrame.tx), Float(toFrame.ty))
        maskShape.sourceSize = SIMD2(Float(fullWidth), Float(fullHeight))
        maskShape.active = 1
        var resample = maskShape
        resample.offset -= SIMD2(Float(sourceOrigin.x), Float(sourceOrigin.y))
        resample.sourceSize = SIMD2(Float(width), Float(height))
        // The map of the whole frame, which the rasterizer keeps small.
        let masks = recipe.masks.filter { $0.enabled }
        let maskMap = masks.isEmpty ? nil : MaskRasterizer.rasterize(masks: masks, width: fullWidth, height: fullHeight)
        let out = try render(cmy, width: width, height: height, resample: resample, maskShape: maskShape,
                             outputWidth: Int(region.width), outputHeight: Int(region.height), maskMap: maskMap,
                             setup: setup, recipe: recipe, glowLongEdge: max(fullWidth, fullHeight),
                             detail: detail, detailScale: 1,
                             origin: SIMD2(Int32(region.minX), Int32(region.minY)),
                             frame: SIMD2(Int32(map.outputWidth), Int32(map.outputHeight)), curves: curves,
                             forDisplay: true, coverage: false, histogram: false)
        return (out.display ?? [], Int(region.width), Int(region.height))
    }

    private func render(_ cmy: [Float], width: Int, height: Int, resample: GeometryUniforms,
                        maskShape: GeometryUniforms, outputWidth ow: Int, outputHeight oh: Int,
                        maskMap: MaskRasterizer.Map?, setup: RenderSetup, recipe: Recipe,
                        glowLongEdge: Int, detail: DetailSettings, detailScale: Double, origin: SIMD2<Int32>,
                        frame: SIMD2<Int32>?, curves: DetailStage.Curves?, forDisplay: Bool,
                        coverage: Bool, histogram: Bool)
        throws -> (pixels: [Float], display: [UInt8]?, curves: DetailStage.Curves?, histogram: PrintHistogram?) {
        let negative = try texture(cmy, width: width, height: height)
        let printed = try texture([], width: ow, height: oh, writable: true)
        let toneLUT = try texture(setup.toneLUT, width: Constants.toneLutWidth, height: Constants.toneLutHeight)
        let dodgeBurn = try maskMap.map { try texture($0.data, width: $0.width, height: $0.height, format: .rg32Float) }
            ?? texture([0, 0], width: 1, height: 1, format: .rg32Float)
        // The spectral tables packed by band, as FLX Film Lab's renderer hands
        // them to print_and_scan.
        let (packed, bandCount) = Renderer.bands(setup.spectralTables)
        let tables = try buffer(packed)
        var bands = bandCount
        let toneShift = try buffer(setup.toneShift.isEmpty ? [0, 0] : setup.toneShift)
        var uniforms = setup.printUniforms
        uniforms.hasDodgeBurn = maskMap == nil ? 0 : 1
        var shape = resample
        var masksShape = maskShape

        guard let cb = queue.makeCommandBuffer() else { throw Failure.allocation }
        var source = negative
        if shape.active != 0 {
            let shaped = try texture([], width: ow, height: oh, writable: true)
            guard let e = cb.makeComputeCommandEncoder() else { throw Failure.allocation }
            e.setTexture(negative, index: 0)
            e.setTexture(shaped, index: 1)
            e.setBytes(&shape, length: MemoryLayout<GeometryUniforms>.stride, index: 0)
            dispatch(e, applyGeometry, width: ow, height: oh)
            e.endEncoding()
            source = shaped
        }
        guard let e = cb.makeComputeCommandEncoder() else { throw Failure.allocation }
        e.setTexture(source, index: 0)
        e.setTexture(printed, index: 1)
        e.setTexture(toneLUT, index: 2)
        e.setTexture(dodgeBurn, index: 3)
        e.setBuffer(tables, offset: 0, index: 0)
        e.setBytes(&uniforms, length: MemoryLayout<PrintUniforms>.stride, index: 1)
        e.setBuffer(toneShift, offset: 0, index: 2)
        e.setBytes(&masksShape, length: MemoryLayout<GeometryUniforms>.stride, index: 3)
        e.setBytes(&bands, length: MemoryLayout<SIMD2<Int32>>.stride, index: 4)
        dispatch(e, printAndScan, width: ow, height: oh)
        e.endEncoding()

        // Sharpening and CLAHE on the print's lightness, before the glow.
        var measured: () -> DetailStage.Curves? = { nil }
        if detail.isActive {
            let done = try detailStage.encode(printed, cb: cb, settings: detail, scale: detailScale,
                                              outputColorSpace: recipe.outputColorSpace, origin: origin,
                                              frame: frame, curves: curves)
            measured = done.measured
            copy(done.texture, to: printed, cb: cb)
        }

        // Bloom & Glow, sized by the frame's long edge, so the preview blooms
        // as the full-size export does and a crop enlarges it like the grain.
        if let look = recipe.effects, look.isActive {
            if effectsContext == nil {
                effectsContext = CIContext(mtlCommandQueue: queue, options: [
                    .workingColorSpace: Self.effectsSpace, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
            }
            let out = try texture([], width: ow, height: oh, writable: true)
            if let context = effectsContext,
               let image = CIImage(mtlTexture: printed, options: [.colorSpace: Self.effectsSpace]) {
                let result = GlowPipeline.apply(look, to: image, longEdge: CGFloat(glowLongEdge))
                context.render(result, to: out, commandBuffer: cb, bounds: image.extent, colorSpace: Self.effectsSpace)
                copy(out, to: printed, cb: cb)
            }
        }
        // The curves, last of all, on the print as its file encodes it (the
        // output space's transfer curve). The histogram is taken of the
        // finished print and, for the curves' graph, of the print they were
        // given. Straight curves are no pass at all: the print stays as it was.
        let encoding: Int32 = recipe.outputColorSpace == "ProPhoto RGB" ? 2 : 1
        let cover: Int32 = coverage ? 1 : 0
        let printCurves = recipe.curves.flatMap { $0.isIdentity ? nil : $0 }
        let bins = histogram ? try histogramBins(printCurves == nil ? 1 : 2) : []
        if bins.count > 1 {
            try measureHistogram(cb, of: printed, into: bins[1], encoding: encoding, coverage: cover, shape: shape)
        }
        if let printCurves {
            let table = try curveBuffer(printCurves)
            var encodingSize = SIMD2<Int32>(encoding, Int32(PrintCurves.tableSize))
            guard let e = cb.makeComputeCommandEncoder() else { throw Failure.allocation }
            e.setTexture(printed, index: 0)
            e.setBuffer(table, offset: 0, index: 0)
            e.setBytes(&encodingSize, length: MemoryLayout<SIMD2<Int32>>.stride, index: 1)
            dispatch(e, applyCurves, width: ow, height: oh)
            e.endEncoding()
        }
        if let after = bins.first {
            try measureHistogram(cb, of: printed, into: after, encoding: encoding, coverage: cover, shape: shape)
        }
        func read(_ buffer: MTLBuffer) -> [UInt32] {
            Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt32.self), count: 768))
        }

        if forDisplay {
            let encoded = try encodeForDisplay(printed, cb: cb, coverage: coverage, encoding: encoding, shape: &shape)
            cb.commit()
            cb.waitUntilCompleted()
            return ([], readback8(encoded), measured(),
                    bins.first.map { PrintHistogram(after: read($0), before: bins.count > 1 ? read(bins[1]) : nil) })
        }
        cb.commit()
        cb.waitUntilCompleted()
        return (readback(printed), nil, measured(),
                bins.first.map { PrintHistogram(after: read($0), before: bins.count > 1 ? read(bins[1]) : nil) })
    }

    /// The curves' table on the GPU (`PrintCurves.table`).
    private func curveBuffer(_ curves: PrintCurves) throws -> MTLBuffer {
        if let kept = curveTable, kept.curves == curves { return kept.buffer }
        let table = curves.table()
        guard let buffer = table.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else { throw Failure.allocation }
        curveTable = (curves, buffer)
        return buffer
    }

    /// `count` histograms' bins, emptied.
    private func histogramBins(_ count: Int) throws -> [MTLBuffer] {
        while histogramBuffers.count < count {
            guard let buffer = device.makeBuffer(length: 768 * MemoryLayout<UInt32>.stride,
                                                 options: .storageModeShared) else { throw Failure.allocation }
            histogramBuffers.append(buffer)
        }
        let buffers = Array(histogramBuffers.prefix(count))
        for buffer in buffers { memset(buffer.contents(), 0, buffer.length) }
        return buffers
    }

    /// Counts the print's pixels into `bins` as the file will encode them;
    /// with `coverage` 1, not the corners outside a levelled frame.
    private func measureHistogram(_ cb: MTLCommandBuffer, of print: MTLTexture, into bins: MTLBuffer,
                                  encoding: Int32, coverage: Int32, shape: GeometryUniforms) throws {
        var encoding = encoding, coverage = coverage, shape = shape
        guard let e = cb.makeComputeCommandEncoder() else { throw Failure.allocation }
        e.setTexture(print, index: 0)
        e.setBuffer(bins, offset: 0, index: 0)
        e.setBytes(&encoding, length: MemoryLayout<Int32>.stride, index: 1)
        e.setBytes(&coverage, length: MemoryLayout<Int32>.stride, index: 2)
        e.setBytes(&shape, length: MemoryLayout<GeometryUniforms>.stride, index: 3)
        dispatch(e, histogramRGB, width: print.width, height: print.height)
        e.endEncoding()
    }

    private func copy(_ from: MTLTexture, to: MTLTexture, cb: MTLCommandBuffer) {
        guard let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: from, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: to.width, height: to.height, depth: 1), to: to,
                  destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }

    /// For the screen, with the output space's transfer curve (`encoding` 1
    /// the sRGB curve, 2 ProPhoto's), so the image is the file's.
    private func encodeForDisplay(_ linear: MTLTexture, cb: MTLCommandBuffer, coverage: Bool, encoding: Int32 = 1,
                                  shape: inout GeometryUniforms) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: linear.width,
                                                         height: linear.height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        guard let out = device.makeTexture(descriptor: d), let e = cb.makeComputeCommandEncoder() else {
            throw Failure.allocation
        }
        var encoding = encoding
        var cover: Int32 = coverage ? 1 : 0
        e.setTexture(linear, index: 0)
        e.setTexture(out, index: 1)
        e.setBytes(&encoding, length: MemoryLayout<Int32>.stride, index: 0)
        e.setBytes(&cover, length: MemoryLayout<Int32>.stride, index: 1)
        e.setBytes(&shape, length: MemoryLayout<GeometryUniforms>.stride, index: 2)
        dispatch(e, encodeDisplay, width: linear.width, height: linear.height)
        e.endEncoding()
        return out
    }

    private func readback8(_ t: MTLTexture) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: t.width * t.height * 4)
        out.withUnsafeMutableBytes { raw in
            t.getBytes(raw.baseAddress!, bytesPerRow: t.width * 4,
                       from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        }
        return out
    }

    /// Any linear RGBA image of the frame (a scan) shaped by `geometry` and
    /// encoded for the screen with the sRGB transfer function.
    func shapeForDisplay(_ px: [Float], width: Int, height: Int, geometry: FrameGeometry,
                         wholeFrame: Bool) throws -> Output {
        let map = GeometryMap(geometry, sourceWidth: width, sourceHeight: height, wholeFrame: wholeFrame)
        let src = try texture(px, width: width, height: height)
        var shape = GeometryUniforms(map)
        guard let cb = queue.makeCommandBuffer() else { throw Failure.allocation }
        var shaped = src
        if !map.isIdentity {
            let dst = try texture([], width: map.outputWidth, height: map.outputHeight, writable: true)
            guard let e = cb.makeComputeCommandEncoder() else { throw Failure.allocation }
            e.setTexture(src, index: 0)
            e.setTexture(dst, index: 1)
            e.setBytes(&shape, length: MemoryLayout<GeometryUniforms>.stride, index: 0)
            dispatch(e, applyGeometry, width: map.outputWidth, height: map.outputHeight)
            e.endEncoding()
            shaped = dst
        }
        let encoded = try encodeForDisplay(shaped, cb: cb, coverage: wholeFrame && !map.isIdentity, shape: &shape)
        cb.commit()
        cb.waitUntilCompleted()
        return Output(pixels: [], display: readback8(encoded), width: map.outputWidth, height: map.outputHeight, map: map,
                      curves: nil)
    }

    /// Paints the pixels of a whole, levelled frame that come from outside
    /// the picture, which the resampling only smears.
    private func mark(_ px: inout [Float], map: GeometryMap, outside: SIMD3<Float>) {
        let w = map.outputWidth, h = map.outputHeight
        let sw = Double(map.sourceSize.width), sh = Double(map.sourceSize.height)
        let t = map.outputToSource
        px.withUnsafeMutableBufferPointer { o in
            let o = o
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(t)
                    if p.x < 0 || p.y < 0 || p.x > sw || p.y > sh {
                        let i = (y * w + x) * 4
                        o[i] = outside.x; o[i + 1] = outside.y; o[i + 2] = outside.z
                    }
                }
            }
        }
    }
}
