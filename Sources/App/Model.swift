import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Observation

// MARK: - Saved settings

/// Every roll's and frame's settings, kept in Application Support by path —
/// never next to the scans, which may live in someone else's folder.
struct Library: Codable {
    var rolls: [String: RollSettings] = [:]
    var frames: [String: FrameSettings] = [:]
    var lastFolder: String?
    var lastRoll: RollSettings?
    /// What each roll and frame was shot with, for the exports' metadata.
    var captures: [String: CaptureInfo] = [:]
    var frameCaptures: [String: FrameCapture] = [:]

    init() {}
    // Every key optional, so a library saved by an earlier build still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rolls = try c.decodeIfPresent([String: RollSettings].self, forKey: .rolls) ?? [:]
        frames = try c.decodeIfPresent([String: FrameSettings].self, forKey: .frames) ?? [:]
        lastFolder = try c.decodeIfPresent(String.self, forKey: .lastFolder)
        lastRoll = try c.decodeIfPresent(RollSettings.self, forKey: .lastRoll)
        captures = try c.decodeIfPresent([String: CaptureInfo].self, forKey: .captures) ?? [:]
        frameCaptures = try c.decodeIfPresent([String: FrameCapture].self, forKey: .frameCaptures) ?? [:]
    }

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FLX Film Convert", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    static func load() -> Library {
        guard let data = try? Data(contentsOf: url),
              let lib = try? JSONDecoder().decode(Library.self, from: data) else { return Library() }
        return lib
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) { try? data.write(to: Library.url, options: .atomic) }
    }
}

// MARK: - Rendering, off the main thread

/// Decodes, finds the base, splits the dyes and prints, on one serial queue,
/// keeping the expensive steps: a print-control change only reprints. Requests
/// that pile up while one renders collapse to the newest.
final class Pipeline {
    struct Request {
        var url: URL
        var roll: RollSettings
        var frame: FrameSettings
        var showScan: Bool
        /// The whole turned, levelled frame, for editing the crop or picking
        /// the rebate, instead of the print's own shape.
        var wholeFrame: Bool
        var generation: Int
        /// What the sidebar's print of these settings is cached under.
        var thumbKey = ""
    }
    struct Output {
        var generation: Int
        var url: URL
        var image: CGImage?
        var map: GeometryMap?
        var field: RebateField?
        var baseNote: String
        var thumbnail: CGImage?
        var thumbKey = ""
        var error: String?
    }

    static let previewSize = 2048
    static let timing = ProcessInfo.processInfo.environment["FLXCONVERT_TIMING"] == "1"
    static var steps = ""
    private var clock = CFAbsoluteTimeGetCurrent()
    private func lap(_ name: String) {
        guard Pipeline.timing else { return }
        let now = CFAbsoluteTimeGetCurrent()
        Pipeline.steps += String(format: "%@ %.1f ", name, (now - clock) * 1000)
        clock = now
    }
    private let queue = DispatchQueue(label: "lab.flx.FLXFilmConvert.render", qos: .userInitiated)
    private var converter: Converter?
    private var scans: [URL: Scan] = [:]
    private var scanOrder: [URL] = []
    private var fields: [String: Result<RebateField, Error>] = [:]
    private var flattened: [String: Scan] = [:]
    private var notUsed: [String: String] = [:]
    private var flattenedOrder: [String] = []
    private var negativeKey = ""
    private var negative: [Float] = []
    private var pending: (Request, (Output) -> Void)?
    private var running = false
    private var nativeLong: [URL: Int] = [:]
    /// The CLAHE curves of the last print of each frame, whole or cropped.
    private var curves: [String: DetailStage.Curves?] = [:]
    /// The frame at full size for the loupe: on the GPU when there is one
    /// (flattened, as the pipeline reads it), else on the CPU.
    private var full: (key: String, width: Int, height: Int, resident: DyeStage.Resident?, scan: Scan?)?
    private var loupePart: (key: String, cmy: [Float])?
    private var loupePending: (LoupeRequest, (LoupeOutput) -> Void)?
    private var loupeRunning = false

    func submit(_ request: Request, completion: @escaping (Output) -> Void) {
        queue.async {
            self.pending = (request, completion)
            guard !self.running else { return }
            self.running = true
            while let (r, done) = self.pending {
                self.pending = nil
                let t0 = CFAbsoluteTimeGetCurrent()
                let out = self.render(r)
                let t1 = CFAbsoluteTimeGetCurrent()
                DispatchQueue.main.async {
                    if Pipeline.timing {
                        print(String(format: "render %.1f ms [%@], to main %.1f ms", (t1 - t0) * 1000,
                                     Pipeline.steps, (CFAbsoluteTimeGetCurrent() - t1) * 1000))
                    }
                    done(out)
                }
            }
            self.running = false
        }
    }

    private func scan(_ url: URL) throws -> Scan {
        if let s = scans[url] { return s }
        let s = try Scan.load(url, maxDimension: Pipeline.previewSize)
        scans[url] = s
        scanOrder.append(url)
        if scanOrder.count > 4 { scans[scanOrder.removeFirst()] = nil }
        return s
    }

    /// The scan the pipeline reads: divided by the roll's light frame when
    /// the roll uses one, and what to say about it.
    private func prepared(_ url: URL, roll: RollSettings, converter: Converter) throws -> (scan: Scan, key: String, note: String) {
        let raw = try scan(url)
        guard roll.useFlatField, let path = roll.flatField else { return (raw, "", "") }
        let key = "\(url.path)|\(path)"
        let name = URL(fileURLWithPath: path).lastPathComponent
        if let s = flattened[key] { return (s, path, "Flat field \(name) takes out the light's falloff. ") }
        if let note = notUsed[key] { return (raw, "", "Flat field not used: \(note). ") }
        let prepared = converter.prepare(raw, url: url, roll: roll)
        guard prepared.used else {
            let note = prepared.note ?? "unreadable"
            notUsed[key] = note
            return (raw, "", "Flat field not used: \(note). ")
        }
        flattened[key] = prepared.scan
        flattenedOrder.append(key)
        if flattenedOrder.count > 4 { flattened[flattenedOrder.removeFirst()] = nil }
        return (prepared.scan, path, "Flat field \(name) takes out the light's falloff. ")
    }

    private func field(_ key: String, _ scan: Scan) -> Result<RebateField, Error> {
        if let f = fields[key] { return f }
        let f = Result { try RebateField.detect(in: scan) }
        fields[key] = f
        return f
    }

    private func render(_ r: Request) -> Output {
        var out = Output(generation: r.generation, url: r.url, image: nil, map: nil, field: nil, baseNote: "",
                         thumbnail: nil, error: nil)
        Pipeline.steps = ""
        clock = CFAbsoluteTimeGetCurrent()
        do {
            if converter == nil { converter = try Converter() }
            let converter = self.converter!
            let (scan, flatKey, flatNote) = try prepared(r.url, roll: r.roll, converter: converter)
            lap("scan")
            let found = field("\(r.url.path)|\(flatKey)", scan)
            lap("field")
            if case .success(let f) = found { out.field = f }
            var base: BaseReference?
            if let pick = r.frame.rebatePick {
                let v = scan.median(pick)
                if v.min() > 0 {
                    base = .uniform(v)
                    out.baseNote = "Picked by hand. Elsewhere the scan's light falloff is not taken out."
                } else {
                    out.baseNote = "The picked area is black. Pick the rebate again."
                }
            } else {
                switch found {
                case .success(let f):
                    base = .field(f)
                    out.baseNote = f.onlyEdge.map { "From the rebate along the \($0) edge only (the other shows none), taken to fall off the same way. " } ?? "From the rebate along both edges. "
                    out.baseNote += String(format: flatKey.isEmpty ? "The light falls off %.2f D across the frame."
                                                                    : "What falloff is left: %.2f D across the frame.", f.falloff)
                case .failure(let e):
                    out.baseNote = "\(e). Pick the rebate by hand."
                }
            }
            out.baseNote = flatNote + out.baseNote
            guard let base, !r.showScan else {
                // The scan itself, scaled so its base sits near white.
                let ref = base.map { pow(10, $0.log(x: 0.5, y: 0.5).max()) }
                    ?? Stats.percentile(stride(from: 1, to: scan.pixels.count, by: 4 * 97).map { scan.pixels[$0] }, 0.99)
                let k = 0.9 / max(ref, 1e-6)
                var scaled = scan.pixels
                for i in stride(from: 0, to: scaled.count, by: 4) { scaled[i] *= k; scaled[i + 1] *= k; scaled[i + 2] *= k }
                let shaped = try converter.printStage.shapeForDisplay(scaled, width: scan.width, height: scan.height,
                                                                      geometry: r.frame.geometry, wholeFrame: true)
                out.map = shaped.map
                out.image = shaped.display.flatMap {
                    Pipeline.image($0, width: shaped.width, height: shaped.height,
                                   space: CGColorSpace(name: CGColorSpace.itur_2020_sRGBGamma)!)
                }
                return out
            }
            let key = "\(r.url.path)|\(r.roll.filmStock)|\(r.roll.lightCCT)|\(String(describing: r.frame.rebatePick))|\(flatKey)"
            if key != negativeKey {
                negative = try converter.negative(of: scan, roll: r.roll, base: base)
                negativeKey = key
            }
            lap("dyes")
            let printed = try converter.print(negative: negative, width: scan.width, height: scan.height,
                                              roll: r.roll, frame: r.frame, wholeFrame: r.wholeFrame, forDisplay: true,
                                              detailScale: detailScale(r.url, scan))
            curves["\(r.url.path)|\(r.wholeFrame)"] = printed.curves
            lap("print")
            out.map = printed.map
            out.image = printed.display.flatMap {
                Pipeline.image($0, width: printed.width, height: printed.height,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            lap("image")
            // The sidebar's thumbnail only once a slider has settled: not while
            // newer requests are waiting behind this one.
            if !r.wholeFrame && pending == nil {
                out.thumbnail = out.image.flatMap { Pipeline.thumbnail($0) }
                out.thumbKey = r.thumbKey
            }
            lap("thumb")
        } catch {
            out.error = "\(error)"
        }
        return out
    }

    /// The preview's pixels per pixel of the scan at full size, which the
    /// sharpening radius is given in.
    private func detailScale(_ url: URL, _ scan: Scan) -> Double {
        if nativeLong[url] == nil { nativeLong[url] = Converter.nativeLongEdge(url) ?? max(scan.width, scan.height) }
        return min(1, Double(max(scan.width, scan.height)) / Double(max(nativeLong[url]!, 1)))
    }

    // MARK: The loupe

    struct LoupeRequest {
        var url: URL
        var roll: RollSettings
        var frame: FrameSettings
        var wholeFrame: Bool
        /// Its centre, in fractions of the print as it shows.
        var centre: CGPoint
        /// Its size in pixels of the screen, one a pixel of the full-size print.
        var width: Int
        var height: Int
        var generation: Int
    }
    struct LoupeOutput {
        var generation: Int
        var url: URL
        var image: CGImage?
        var error: String?
    }

    /// The print at 100%: the part of it under the loupe, printed from the
    /// scan at full size. The full-size scan is decoded once (as the export
    /// decodes it) and kept while the loupe is open on that frame; only the
    /// part under the loupe is flattened, split into dyes and printed. The
    /// base is the preview's, and CLAHE the curves of the print on screen.
    func loupe(_ request: LoupeRequest, completion: @escaping (LoupeOutput) -> Void) {
        queue.async {
            self.loupePending = (request, completion)
            guard !self.loupeRunning else { return }
            self.loupeRunning = true
            while let (r, done) = self.loupePending {
                self.loupePending = nil
                let out = self.renderLoupe(r)
                DispatchQueue.main.async { done(out) }
            }
            self.loupeRunning = false
        }
    }

    /// Lets go of the full-size scan (about 400 MB for 24 MP, 700 for 45).
    func releaseFullSize() {
        queue.async { self.full = nil; self.loupePart = nil }
    }

    private func renderLoupe(_ r: LoupeRequest) -> LoupeOutput {
        var out = LoupeOutput(generation: r.generation, url: r.url, image: nil, error: nil)
        Pipeline.steps = ""
        clock = CFAbsoluteTimeGetCurrent()
        defer { if Pipeline.timing { print("loupe [\(Pipeline.steps)]") } }
        do {
            if converter == nil { converter = try Converter() }
            let converter = self.converter!
            // The base as the preview measured it, and the flat field it reads.
            let (preview, flatKey, _) = try prepared(r.url, roll: r.roll, converter: converter)
            let fullKey = "\(r.url.path)|\(flatKey)"
            if full?.key != fullKey {
                full = nil
                loupePart = nil
                try autoreleasepool {
                    var scan = try Scan.load(r.url, maxDimension: nil)
                    if !flatKey.isEmpty { scan = converter.prepare(scan, url: r.url, roll: r.roll).scan }
                    if let stage = converter.dyeStage, let resident = try? stage.resident(scan) {
                        full = (fullKey, scan.width, scan.height, resident, nil)
                    } else {
                        full = (fullKey, scan.width, scan.height, nil, scan)
                    }
                }
            }
            lap("full size")
            let fw = full!.width, fh = full!.height
            let map = GeometryMap(r.frame.geometry, sourceWidth: fw, sourceHeight: fh, wholeFrame: r.wholeFrame)
            let ow = map.outputWidth, oh = map.outputHeight
            // The loupe's part of the print, with a margin the sharpening's
            // blur reads past, then cut off.
            let pad = r.frame.sharpness > 0 ? Int((3 * r.frame.sharpenRadius).rounded(.up)) + 2 : 2
            let rw = min(r.width + 2 * pad, ow), rh = min(r.height + 2 * pad, oh)
            let cx = Double(r.centre.x) * Double(ow), cy = Double(r.centre.y) * Double(oh)
            let x0 = min(max(Int((cx - Double(rw) / 2).rounded()), 0), ow - rw)
            let y0 = min(max(Int((cy - Double(rh) / 2).rounded()), 0), oh - rh)
            let region = CGRect(x: x0, y: y0, width: rw, height: rh)
            // Where it comes from in the scan, and 3 pixels round for the resampling.
            let corners = [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY),
                           CGPoint(x: region.minX, y: region.maxY), CGPoint(x: region.maxX, y: region.maxY)]
                .map { $0.applying(map.outputToSource) }
            let sx0 = max(Int(corners.map(\.x).min()!.rounded(.down)) - 3, 0)
            let sy0 = max(Int(corners.map(\.y).min()!.rounded(.down)) - 3, 0)
            let sx1 = min(Int(corners.map(\.x).max()!.rounded(.up)) + 3, fw)
            let sy1 = min(Int(corners.map(\.y).max()!.rounded(.up)) + 3, fh)
            guard sx1 - sx0 > 4, sy1 - sy0 > 4 else { return out }
            let box = (x: sx0, y: sy0, width: sx1 - sx0, height: sy1 - sy0)

            let field = try? self.field("\(r.url.path)|\(flatKey)", preview).get()
            let base: BaseReference
            if let pick = r.frame.rebatePick, preview.median(pick).min() > 0 {
                base = .uniform(preview.median(pick))
            } else if let field {
                base = .field(field)
            } else {
                throw PictureFinder.Failure.noBase
            }
            let key = "\(r.url.path)|\(r.roll.filmStock)|\(r.roll.lightCCT)|\(String(describing: r.frame.rebatePick))|\(flatKey)|\(box)"
            if loupePart?.key != key {
                let cmy: [Float]
                if let resident = full!.resident, let stage = converter.dyeStage {
                    cmy = try stage.negative(of: resident, box: box, base: base, unmixer: try converter.unmixer(for: r.roll))
                } else {
                    let part = full!.scan!.cropped(to: box)
                    cmy = try converter.negative(of: part, roll: r.roll, base: base,
                                                 part: (CGPoint(x: box.x, y: box.y), fw, fh))
                }
                loupePart = (key, cmy)
            }
            lap("dyes")
            let recipe = Recipe.forPrint(roll: r.roll, frame: r.frame)
            let setup = try RenderSetupBuilder.build(recipe: recipe, exposureEV: 0)
            let printed = try converter.printStage.printRegion(
                negative: loupePart!.cmy, width: box.width, height: box.height,
                sourceOrigin: CGPoint(x: box.x, y: box.y), fullWidth: fw, fullHeight: fh, region: region,
                setup: setup, recipe: recipe, geometry: r.frame.geometry, wholeFrame: r.wholeFrame,
                detail: r.frame.detail, curves: curves["\(r.url.path)|\(r.wholeFrame)"] ?? nil)
            lap("print")
            // The window the loupe asked for, centred on its point.
            let w = min(r.width, rw), h = min(r.height, rh)
            let wx = min(max(Int((cx - Double(w) / 2).rounded()) - x0, 0), rw - w)
            let wy = min(max(Int((cy - Double(h) / 2).rounded()) - y0, 0), rh - h)
            var window = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                let src = ((wy + y) * rw + wx) * 4
                window.replaceSubrange((y * w * 4)..<((y + 1) * w * 4), with: printed.display[src..<(src + w * 4)])
            }
            out.image = Pipeline.image(window, width: w, height: h, space: CGColorSpace(name: CGColorSpace.sRGB)!)
        } catch {
            out.error = "\(error)"
        }
        return out
    }

    /// The print exposure an enlarger meter would give this frame's crop.
    func meter(url: URL, roll: RollSettings, frame: FrameSettings, completion: @escaping (Double?) -> Void) {
        queue.async {
            var value: Double?
            if let scan = self.scans[url], !self.negative.isEmpty,
               self.negativeKey.hasPrefix(url.path + "|"),
               let film = try? PackLibrary.shared.pack(roll.filmStock) {
                value = PrintMeter.exposure(negative: self.negative, width: scan.width, height: scan.height,
                                            geometry: frame.geometry, film: film)
            }
            DispatchQueue.main.async { completion(value) }
        }
    }

    /// The picture's edges on a frame's preview, from its rebate and frame
    /// gaps (`PictureFinder`), for Crop to Picture.
    func findPicture(url: URL, roll: RollSettings, frame: FrameSettings,
                     completion: @escaping (Result<PictureFrame, Error>) -> Void) {
        queue.async {
            let result = Result { () throws -> PictureFrame in
                if self.converter == nil { self.converter = try Converter() }
                let (scan, flatKey, _) = try self.prepared(url, roll: roll, converter: self.converter!)
                let field = try? self.field("\(url.path)|\(flatKey)", scan).get()
                let base: BaseReference
                if let pick = frame.rebatePick, scan.median(pick).min() > 0 {
                    base = .uniform(scan.median(pick))
                } else if let field {
                    base = .field(field)
                } else {
                    throw PictureFinder.Failure.noBase
                }
                guard let found = PictureFinder.find(in: scan, base: base, field: field) else {
                    throw PictureFinder.Failure.noPicture
                }
                return found
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The field found on a frame's preview, if any, for export to reuse.
    func knownField(_ url: URL, roll: RollSettings) -> RebateField? {
        let flat = roll.useFlatField ? (roll.flatField ?? "") : ""
        return queue.sync { if case .success(let f) = fields["\(url.path)|\(flat)"] { return f } else { return nil } }
    }

    // MARK: Images

    /// An 8-bit image of `encode_display`'s output: premultiplied, the
    /// transfer function already applied, so the screen only composites it.
    static func image(_ bytes: [UInt8], width: Int, height: Int, space: CGColorSpace) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func thumbnail(_ image: CGImage, size: Int = 220) -> CGImage? {
        let scale = Double(size) / Double(max(image.width, image.height))
        let w = max(Int(Double(image.width) * scale), 1), h = max(Int(Double(image.height) * scale), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

// MARK: - The app's state

enum Tool: Equatable { case none, pickRebate }

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG", tiff = "TIFF 16-bit"
    var id: String { rawValue }
    var engine: PrintExporter.Format { self == .jpeg ? .jpeg : .tiff16 }
    var ext: String { self == .jpeg ? "jpg" : "tif" }
}

/// What changes with every render: watched by the canvas alone, so a slider
/// moving does not redraw the inspector each time the print comes back.
@MainActor @Observable
final class Preview {
    var image: CGImage? { didSet { onImage?() } }
    var rendering = false
    /// Called when a print arrives (the self-check's sweep).
    @ObservationIgnored var onImage: (() -> Void)?
}

/// The sidebar's thumbnails, watched by the sidebar alone.
@MainActor @Observable
final class Thumbnails {
    var images: [URL: CGImage] = [:]
}

/// The app's state. Observable property by property, so a view redraws only
/// when something it reads changes: moving a slider redraws that slider's
/// section, not the whole inspector.
@MainActor @Observable
final class ConvertModel {
    struct Frame: Identifiable, Hashable {
        let url: URL
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    var folder: URL?
    var frames: [Frame] = []
    var selection: URL? { didSet { if selection != oldValue { selectionChanged() } } }
    var roll = RollSettings() {
        didSet {
            guard roll != oldValue else { return }
            settingsChanged()
            if !loading { scheduleThumbnails() }
        }
    }
    var frame = FrameSettings() { didSet { if frame != oldValue { settingsChanged() } } }
    let preview = Preview()
    let thumbnails = Thumbnails()
    /// What the roll was shot with, and this frame's own lens and date: only
    /// for the exports' metadata, so a change here never reprints.
    var capture = CaptureInfo() {
        didSet {
            guard capture != oldValue, !loading, let folder else { return }
            library.captures[folder.path] = capture
            scheduleSave()
        }
    }
    var frameCapture = FrameCapture() {
        didSet {
            guard frameCapture != oldValue, !loading, let url = selection else { return }
            library.frameCaptures[url.path] = frameCapture == FrameCapture() ? nil : frameCapture
            scheduleSave()
        }
    }

    /// The caption the selected frame's export will carry.
    var exportCaption: String {
        ExportMetadata.description(print: Converter.printInfo(roll: effectiveRoll), capture: capture.applying(frameCapture),
                                   source: selectionMetadata)
    }
    /// The selected scan's own metadata, read once.
    @ObservationIgnored private var selectionMetadata: [CFString: Any]?
    var filmSpeed: Int? { ExportMetadata.speed(stock: effectiveRoll.filmStock) }

    /// What frames have of their own (a film, a filter pack), for the sidebar.
    var frameNotes: [URL: String] = [:]
    /// Where the image on screen comes from in the frame: its shape. Set only
    /// when it changes.
    var displayMap: GeometryMap?
    var showScan = false { didSet { if showScan != oldValue { render() } } }
    /// The loupe: the print at 100% (a pixel of the full-size print to a
    /// pixel of the screen) where it stands on the print.
    var loupeOn = false {
        didSet {
            guard loupeOn != oldValue else { return }
            if loupeOn { requestLoupe() } else { loupeImage = nil; loupeLoading = false; pipeline.releaseFullSize() }
        }
    }
    /// Its centre, in fractions of the print as it shows.
    var loupeCentre = CGPoint(x: 0.5, y: 0.5)
    var loupeImage: CGImage?
    var loupeLoading = false
    /// Its size in pixels of the screen, set by the canvas.
    @ObservationIgnored var loupePixels = (width: 600, height: 600)
    @ObservationIgnored private var loupeGeneration = 0
    var showStrips = true
    var field: RebateField?
    var baseNote = ""
    var error: String?
    var tool: Tool = .none { didSet { if tool != oldValue { render() } } }
    var selectedMask: UUID?
    /// Showing the whole frame with the crop on it, to edit the crop.
    var isCropping = false {
        didSet {
            guard isCropping != oldValue else { return }
            if !isCropping { isLevelling = false }
            render()
        }
    }
    /// The level tool: a line drawn on the picture along a horizon or an upright.
    var isLevelling = false { didSet { if isLevelling { isCropping = true } } }
    var exportFormat: ExportFormat = .jpeg
    var exportSize = 0                  // long edge in pixels; 0 is the camera's full size
    var outputColorSpace = "sRGB"
    var exportStatus: String?

    /// The film menus: the stocks still on sale (`FilmCatalogue`), and the
    /// roll's and this frame's, whatever they are.
    var films: [(title: String, entries: [PackIndexEntry])] {
        FilmCatalogue.groups(including: [roll.filmStock, frame.filmStock])
    }
    let papers: [(title: String, entries: [PackIndexEntry])]
    let colorSpaces: [String]

    @ObservationIgnored private var library = Library.load()
    @ObservationIgnored private let pipeline = Pipeline()
    @ObservationIgnored private let thumbnailMaker = ThumbnailMaker()
    @ObservationIgnored private var thumbnailWork: DispatchWorkItem?
    /// Off in the self-check unless asked for, so its snapshots stay quick.
    @ObservationIgnored var makesThumbnails = true
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    init() {
        let lib = PackLibrary.shared
        papers = PackIndexEntry.groups(lib.printStocks, films: false)
        colorSpaces = lib.shared_.outputColorSpaces
    }

    /// Reopens the last roll; called once the window is up, so the property
    /// observers run as for any other change.
    func restore() {
        guard folder == nil else { return }
        if let last = library.lastRoll { loading = true; roll = last; loading = false }
        if let path = library.lastFolder, FileManager.default.fileExists(atPath: path) {
            open(folder: URL(fileURLWithPath: path))
        }
    }

    var selectedFrame: Frame? { frames.first { $0.url == selection } }
    /// The roll as the selected frame prints it.
    var effectiveRoll: RollSettings { roll.applying(frame) }
    var filmPack: ProfilePack? { try? PackLibrary.shared.pack(effectiveRoll.filmStock) }
    var paperPack: ProfilePack? {
        try? PackLibrary.shared.pack(roll.printStock ?? filmPack?.targetPrint ?? "")
    }
    var paperName: String { paperPack?.name ?? "" }
    /// "Film on paper", for the window's subtitle; stored, and set only when it
    /// changes, so the window and its toolbar do not redraw with every slider.
    private(set) var rollTitle = ""
    private func updateRollTitle() {
        let title = "\(filmPack?.name ?? "") on \(paperName)"
        if title != rollTitle { rollTitle = title }
    }
    var printsInSilver: Bool { paperPack?.isMonochrome == true }
    /// The turned frame the crop is drawn on, in preview pixels.
    var turnedFrame: CGSize? { displayMap?.frame }

    // MARK: Folder and frames

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Roll"
        panel.message = "Choose a folder of camera scans of one roll"
        if panel.runModal() == .OK, let url = panel.url { open(folder: url) }
    }

    func open(folder url: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        let raws = files.filter { Scan.rawExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        folder = url
        frames = raws.map { Frame(url: $0) }
        frameNotes = Dictionary(uniqueKeysWithValues: raws.compactMap { u in
            library.frames[u.path].flatMap(Self.note).map { (u, $0) }
        })
        thumbnails.images = [:]
        library.lastFolder = url.path
        loading = true
        roll = library.rolls[url.path] ?? library.lastRoll ?? RollSettings()
        capture = library.captures[url.path] ?? CaptureInfo()
        loading = false
        scheduleSave()
        selection = frames.first?.url
        loadThumbnails(raws)
        refreshThumbnails()
    }

    // MARK: The sidebar's prints

    /// The sidebar's prints of every frame but the one on screen (the
    /// pipeline prints that), from the cache where nothing changed and made
    /// in the background where something did.
    func refreshThumbnails() {
        guard makesThumbnails else { return }
        let jobs = frames.compactMap { f -> ThumbnailMaker.Job? in
            guard f.url != selection else { return nil }
            let settings = library.frames[f.url.path] ?? FrameSettings()
            let r = roll.applying(settings)
            return ThumbnailMaker.Job(url: f.url, roll: r, frame: settings,
                                      key: ThumbnailCache.key(f.url, roll: r, frame: settings))
        }
        thumbnailMaker.make(jobs) { [weak self] job, image in
            guard let self, self.frames.contains(where: { $0.url == job.url }) else { return }
            self.thumbnails.images[job.url] = image
        }
    }

    /// After the roll's settings change, once they have settled: a slider
    /// dragged does not start the whole roll at every step.
    private func scheduleThumbnails() {
        thumbnailMaker.cancel()
        thumbnailWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshThumbnails() }
        thumbnailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func loadThumbnails(_ urls: [URL]) {
        DispatchQueue.global(qos: .utility).async {
            for url in urls {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                             kCGImageSourceThumbnailMaxPixelSize: 220,
                                             kCGImageSourceCreateThumbnailWithTransform: true]
                guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { continue }
                DispatchQueue.main.async {
                    if self.thumbnails.images[url] == nil { self.thumbnails.images[url] = thumb }
                }
            }
        }
    }

    private func selectionChanged() {
        guard let url = selection else { preview.image = nil; return }
        loading = true
        frame = library.frames[url.path] ?? FrameSettings()
        frameCapture = library.frameCaptures[url.path] ?? FrameCapture()
        selectionMetadata = RawLoader.metadata(of: url)
        loading = false
        field = nil
        displayMap = nil
        tool = .none
        selectedMask = nil
        isCropping = false
        loupeImage = nil
        render()
    }

    func select(offset: Int) {
        guard let i = frames.firstIndex(where: { $0.url == selection }) else { return }
        let j = min(max(i + offset, 0), frames.count - 1)
        selection = frames[j].url
    }

    // MARK: Settings

    private static func filmName(_ stock: String) -> String { (try? PackLibrary.shared.pack(stock))?.name ?? stock }

    /// "Kodak Gold 200 · Temp −10 Tint +5": what a frame has of its own.
    private static func note(_ f: FrameSettings) -> String? {
        let parts = [f.filmStock.map(filmName),
                     f.filtration.map {
                         String(format: "Temp %+.0f Tint %+.0f", (Controls.temperature.fromPhysical($0.yellow) + 0).rounded(),
                                (Controls.tint.fromPhysical($0.magenta) + 0).rounded()).replacingOccurrences(of: "-", with: "−")
                     }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func settingsChanged() {
        updateRollTitle()
        if let url = selection {
            let own = Self.note(frame)
            if frameNotes[url] != own { frameNotes[url] = own }
        }
        guard !loading else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        if let folder { library.rolls[folder.path] = roll }
        library.lastRoll = roll
        if let url = selection { library.frames[url.path] = frame }
        let t1 = CFAbsoluteTimeGetCurrent()
        scheduleSave()
        let t2 = CFAbsoluteTimeGetCurrent()
        render()
        let t3 = CFAbsoluteTimeGetCurrent()
        if ProcessInfo.processInfo.environment["FLXCONVERT_TIMING"] == "1" {
            print(String(format: "settingsChanged: library %.1f ms, save %.1f ms, render submit %.1f ms",
                         (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000))
        }
    }

    /// Off for the self-check, so its settings never reach the library.
    @ObservationIgnored var persists = true

    private func scheduleSave() {
        guard persists else { return }
        saveWork?.cancel()
        let lib = library
        let work = DispatchWorkItem { lib.save() }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func render() {
        guard let url = selection else { return }
        generation += 1
        if !preview.rendering { preview.rendering = true }
        var request = Pipeline.Request(url: url, roll: effectiveRoll, frame: frame, showScan: showScan,
                                       wholeFrame: isCropping || tool == .pickRebate, generation: generation)
        if !showScan { request.thumbKey = ThumbnailCache.key(url, roll: effectiveRoll, frame: frame) }
        pipeline.submit(request) { [weak self] out in
            guard let self else { return }
            if let thumb = out.thumbnail, !out.thumbKey.isEmpty {
                self.thumbnails.images[out.url] = thumb
                let key = out.thumbKey
                DispatchQueue.global(qos: .utility).async { ThumbnailCache.save(thumb, key: key) }
            }
            guard out.generation == self.generation else { return }
            self.preview.rendering = false
            self.preview.image = out.image
            // The rest only when it changed, so the inspector redraws only then.
            if !Self.same(self.displayMap, out.map) { self.displayMap = out.map }
            if self.field != out.field { self.field = out.field }
            if self.baseNote != out.baseNote { self.baseNote = out.baseNote }
            if self.error != out.error { self.error = out.error }
        }
        requestLoupe()
    }

    private static func same(_ a: GeometryMap?, _ b: GeometryMap?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.outputWidth == b.outputWidth && a.outputHeight == b.outputHeight && a.frame == b.frame
            && a.crop == b.crop && a.sourceSize == b.sourceSize && a.sourceToOutput == b.sourceToOutput
    }

    // MARK: Loupe

    func moveLoupe(to p: CGPoint) {
        let c = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
        guard c != loupeCentre else { return }
        loupeCentre = c
        requestLoupe()
    }

    func requestLoupe() {
        guard loupeOn, !showScan, let url = selection else { return }
        loupeGeneration += 1
        if loupeImage == nil { loupeLoading = true }
        let request = Pipeline.LoupeRequest(url: url, roll: effectiveRoll, frame: frame,
                                            wholeFrame: isCropping || tool == .pickRebate, centre: loupeCentre,
                                            width: loupePixels.width, height: loupePixels.height,
                                            generation: loupeGeneration)
        pipeline.loupe(request) { [weak self] out in
            guard let self, self.loupeOn, out.url == self.selection else { return }
            self.loupeLoading = false
            if let image = out.image { self.loupeImage = image }
            if let error = out.error { self.error = error }
        }
    }

    // MARK: Print

    func meter() {
        guard let url = selection else { return }
        pipeline.meter(url: url, roll: effectiveRoll, frame: frame) { [weak self] value in
            if let value { self?.frame.exposure = (value * 10).rounded() / 10 }
        }
    }

    // MARK: Resets, section by section

    private static let blank = FrameSettings()

    var printIsDefault: Bool {
        let d = Self.blank
        return frame.exposure == d.exposure && frame.brightness == d.brightness && frame.grade == nil
            && frame.shadowGrade == d.shadowGrade && frame.highlightGrade == d.highlightGrade
    }
    func resetPrint() {
        let d = Self.blank
        frame.exposure = d.exposure; frame.brightness = d.brightness; frame.grade = nil
        frame.shadowGrade = d.shadowGrade; frame.highlightGrade = d.highlightGrade
    }

    var toneIsDefault: Bool {
        let d = Self.blank
        return frame.shadows == d.shadows && frame.highlights == d.highlights && frame.toe == d.toe
            && frame.toeWidth == d.toeWidth && frame.shoulder == d.shoulder
            && frame.shoulderWidth == d.shoulderWidth && frame.snap == d.snap
    }
    func resetTone() {
        let d = Self.blank
        frame.shadows = d.shadows; frame.highlights = d.highlights
        frame.toe = d.toe; frame.toeWidth = d.toeWidth; frame.shoulder = d.shoulder
        frame.shoulderWidth = d.shoulderWidth; frame.snap = d.snap
    }

    var detailIsDefault: Bool {
        let d = Self.blank
        return frame.sharpness == d.sharpness && frame.sharpenRadius == d.sharpenRadius
            && frame.sharpenMasking == d.sharpenMasking && frame.localContrast == d.localContrast
    }
    func resetDetail() {
        let d = Self.blank
        frame.sharpness = d.sharpness; frame.sharpenRadius = d.sharpenRadius
        frame.sharpenMasking = d.sharpenMasking; frame.localContrast = d.localContrast
    }

    var colourIsDefault: Bool { frame.shadowCMY == .zero && frame.highlightCMY == .zero && frame.preflash == 0 }
    func resetColour() {
        frame.shadowCMY = .zero; frame.highlightCMY = .zero; frame.preflash = 0
    }

    // MARK: Filtration, the roll's or this frame's

    /// Whether this frame prints with a filter pack of its own.
    var filtersThisFrame: Bool { frame.filtration != nil }

    /// This frame gets a pack of its own, starting from the roll's, or goes
    /// back to the roll's.
    func setFiltersThisFrame(_ own: Bool) {
        if own {
            if frame.filtration == nil { frame.filtration = Filtration(yellow: roll.filterY, magenta: roll.filterM) }
        } else {
            frame.filtration = nil
        }
    }

    /// The pack the sliders move: this frame's own, or else the roll's.
    var filterY: Double {
        get { frame.filtration?.yellow ?? roll.filterY }
        set { if frame.filtration != nil { frame.filtration?.yellow = newValue } else { roll.filterY = newValue } }
    }
    var filterM: Double {
        get { frame.filtration?.magenta ?? roll.filterM }
        set { if frame.filtration != nil { frame.filtration?.magenta = newValue } else { roll.filterM = newValue } }
    }

    /// Back to the stock's own neutral pack, for the pack the sliders move.
    func resetFiltration() {
        if frame.filtration != nil { frame.filtration = Filtration() } else { roll.filterY = 0; roll.filterM = 0 }
    }

    var crossoverIsDefault: Bool {
        roll.gradeTrim == .zero && roll.toeTrim == .zero && roll.shoulderTrim == .zero && roll.snapTrim == .zero
    }
    func resetCrossover() {
        roll.gradeTrim = .zero; roll.toeTrim = .zero; roll.shoulderTrim = .zero; roll.snapTrim = .zero
    }

    /// There is no undo yet, so the resets that throw away work ask first.
    private func confirm(_ message: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func removeAllMasks() {
        guard !frame.masks.isEmpty,
              confirm("Remove all \(frame.masks.count) masks?", detail: "The dodging and burning of this frame goes.",
                      button: "Remove") else { return }
        selectedMask = nil
        frame.masks = []
    }

    /// The frame back to how it opened: print, tone, colour, masks, effects, crop
    /// and a picked rebate. A film chosen for this frame alone stays.
    func resetFrame() {
        guard frame != FrameSettings(),
              confirm("Reset this frame?", detail: "Its print, tone, colour, its own filtration, masks, effects and crop go back to the start. Its film, and the roll's paper and filtration, stay.",
                      button: "Reset") else { return }
        var fresh = FrameSettings()
        fresh.filmStock = frame.filmStock
        selectedMask = nil
        isCropping = false
        frame = fresh
    }

    // MARK: Flat field

    /// Chooses the roll's light frame: any raw file of the bare light.
    func chooseFlatField() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.directoryURL = roll.flatField.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? folder
        panel.prompt = "Use as Flat Field"
        panel.message = "Choose a frame of the bare light, shot with this roll's camera, lens, aperture and holder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useAsFlatField(url)
    }

    func useAsFlatField(_ url: URL) {
        roll.flatField = url.path
        roll.useFlatField = true
    }

    // MARK: Crop & straighten (as FLX Film Lab's DocumentModel does it)

    func editGeometry(_ change: (inout FrameGeometry, CGSize) -> Void) {
        guard let frameSize = turnedFrame else { return }
        var g = frame.geometry
        change(&g, frameSize)
        frame.geometry = g
    }

    func turn(clockwise: Bool) { frame.geometry.turn(clockwise: clockwise) }
    func flip(horizontal: Bool) { frame.geometry.flip(horizontal: horizontal) }
    func setCropAspect(_ aspect: CropAspect) { editGeometry { g, f in g.setAspect(aspect, frame: f) } }
    func swapCropOrientation() { editGeometry { g, f in g.swapOrientation(frame: f) } }
    func setStraighten(_ degrees: Double) { frame.geometry.setStraighten(degrees) }
    func resetGeometry() { frame.geometry = FrameGeometry() }

    func setCustomAspect(width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        editGeometry { g, f in
            g.customWidth = width
            g.customHeight = height
            g.setAspect(.custom, frame: f)
        }
    }

    /// Level the picture along a line drawn on it, from `a` to `b` in the
    /// frame as it shows while cropping (normalised): the line comes out
    /// level, or upright if it is nearer upright.
    func level(from a: CGPoint, to b: CGPoint) {
        editGeometry { g, f in
            let dx = Double(b.x - a.x) * Double(f.width), dy = Double(b.y - a.y) * Double(f.height)
            guard dx * dx + dy * dy > 4 else { return }
            let angle = atan2(dy, dx) * 180 / .pi
            g.setStraighten(g.straighten - (angle - 90 * (angle / 90).rounded()))
        }
    }

    /// What Crop to Picture last said, when it could not find the picture
    /// or found only some of its edges.
    var pictureNote: String?

    /// Levels the print by the picture's own edges and crops it to them, a
    /// little inside, so the gate's rounded corners and soft edge stay out:
    /// found from the rebate and the gaps between frames (`PictureFinder`),
    /// never from what the picture shows. Undone by Reset crop.
    func cropToPicture(then done: (() -> Void)? = nil) {
        guard let url = selection else { done?(); return }
        pictureNote = nil
        pipeline.findPicture(url: url, roll: effectiveRoll, frame: frame) { [weak self] result in
            defer { done?() }
            guard let self, self.selection == url else { return }
            switch result {
            case .failure(let error):
                self.pictureNote = "\(error)"
            case .success(let picture):
                self.apply(picture)
                let missing = (2 - picture.longEdgesFound) + (2 - picture.endsFound)
                if missing > 0 {
                    self.pictureNote = missing == 1 ? "One edge did not show; it is taken where the film or the scan ends."
                        : "\(missing) edges did not show; they are taken where the film or the scan ends."
                }
            }
        }
    }

    private func apply(_ picture: PictureFrame) {
        guard let map = displayMap else { return }
        let size = (width: Int(map.sourceSize.width), height: Int(map.sourceSize.height))
        // The picture in the turned frame, unlevelled.
        var plain = frame.geometry
        plain.straighten = 0
        plain.crop = nil
        plain.aspect = .free
        let turned = GeometryMap(plain, sourceWidth: size.width, sourceHeight: size.height, wholeFrame: true)
        let corners = picture.corners.map { turned.outputPoint(fromNormalised: $0) }
        // Level it as the Level line does, by its first (long) edge.
        let angle = atan2(Double(corners[1].y - corners[0].y), Double(corners[1].x - corners[0].x)) * 180 / .pi
        var g = frame.geometry
        g.aspect = .free
        // To a hundredth of a degree, and none under 0.05°, which the edges
        // cannot tell from level (they agree to about 0.04°).
        let straighten = (-(angle - 90 * (angle / 90).rounded()) * 100).rounded() / 100
        g.setStraighten(abs(straighten) < 0.05 ? 0 : straighten)
        // The corners levelled; the crop is the rectangle inside them, drawn
        // in by 0.6% of its short side.
        var levelled = g
        levelled.crop = nil
        let level = GeometryMap(levelled, sourceWidth: size.width, sourceHeight: size.height, wholeFrame: true)
        let p = picture.corners.map { level.outputPoint(fromNormalised: $0) }
        let xs = p.map(\.x).sorted(), ys = p.map(\.y).sorted()
        var rect = CGRect(x: xs[1], y: ys[1], width: xs[2] - xs[1], height: ys[2] - ys[1])
        let inset = 0.006 * min(rect.width, rect.height)
        rect = rect.insetBy(dx: inset, dy: inset)
        g.setCrop(g.fitted(rect, frame: level.frame), frame: level.frame)
        frame.geometry = g
    }

    // MARK: Dodge & burn (FLX Film Lab's masks)

    /// Points given in the print as it shows (normalised) back in the frame,
    /// where masks are stored.
    func framePoints(_ points: [CGPoint]) -> [CGPoint] {
        guard let map = displayMap, !map.isIdentity else { return points }
        return points.map { map.normalisedSource(fromOutput: CGPoint(x: $0.x * CGFloat(map.outputWidth),
                                                                      y: $0.y * CGFloat(map.outputHeight))) }
    }

    func addMask(_ shape: MaskShape) {
        var mask = LocalMask()
        mask.shape = shape
        mask.name = "\(shape == .gradient ? "Graduated" : shape.rawValue.capitalized) \(frame.masks.count + 1)"
        switch shape {
        case .polygon:
            mask.points = framePoints([CGPoint(x: 0.35, y: 0.35), CGPoint(x: 0.65, y: 0.35),
                                       CGPoint(x: 0.65, y: 0.65), CGPoint(x: 0.35, y: 0.65)])
        case .oval:
            mask.points = framePoints([CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.72, y: 0.5), CGPoint(x: 0.5, y: 0.72)])
        case .gradient:
            // A burnt-in sky: full at the top edge, gone by the middle.
            mask.points = framePoints([CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.5, y: 0.5)])
        }
        mask.stops = 0.5
        isCropping = false
        frame.masks.append(mask)
        selectedMask = mask.id
    }

    func deleteMask(_ id: UUID) {
        if selectedMask == id { selectedMask = nil }
        frame.masks.removeAll { $0.id == id }
    }

    // MARK: Export

    func exportFrame() {
        guard let frameItem = selectedFrame else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = frameItem.name + "." + exportFormat.ext
        panel.allowedContentTypes = [exportFormat == .jpeg ? .jpeg : .tiff]
        guard panel.runModal() == .OK, let out = panel.url else { return }
        export([(frameItem.url, out)])
    }

    func exportRoll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where the prints of the whole roll go"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        export(frames.map { ($0.url, dir.appendingPathComponent($0.name + "." + exportFormat.ext)) })
    }

    private func export(_ jobs: [(URL, URL)]) {
        let roll = self.roll
        let settings = jobs.map { selection == $0.0 ? frame : (library.frames[$0.0.path] ?? FrameSettings()) }
        let captures = jobs.map { capture.applying(selection == $0.0 ? frameCapture : library.frameCaptures[$0.0.path]) }
        let fields = jobs.enumerated().map { pipeline.knownField($0.element.0, roll: roll.applying(settings[$0.offset])) }
        let format = exportFormat.engine
        let size: Int? = exportSize == 0 ? nil : exportSize
        let space = outputColorSpace
        exportStatus = "Exporting…"
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            do {
                let converter = try Converter()
                for (k, job) in jobs.enumerated() {
                    DispatchQueue.main.async { self.exportStatus = "Exporting \(k + 1) of \(jobs.count): \(job.0.lastPathComponent)" }
                    do {
                        try converter.export(job.0, roll: roll.applying(settings[k]), frame: settings[k], field: fields[k],
                                             to: job.1, format: format, maxDimension: size, outputColorSpace: space,
                                             capture: captures[k])
                    } catch {
                        failures.append("\(job.0.lastPathComponent): \(error)")
                    }
                }
            } catch {
                failures.append("\(error)")
            }
            DispatchQueue.main.async {
                self.exportStatus = failures.isEmpty ? "Exported \(jobs.count) print\(jobs.count == 1 ? "" : "s")."
                                                     : "Exported with \(failures.count) failed: " + failures.joined(separator: "; ")
            }
        }
    }
}
