import Foundation
import CoreImage
import ImageIO
import CoreGraphics

/// Work on a scan at full size, one at a time across the app: a 45 MP frame
/// takes 3 to 6 GB while it is decoded, split and printed, and two at once
/// (an export and the loupe) could push a 16 GB Mac out of memory, which
/// stalls the app until it is force-quit. Never waited for on the main thread.
enum FullSize {
    private static let gate = DispatchSemaphore(value: 1)

    static func run<T>(_ body: () throws -> T) rethrows -> T {
        gate.wait()
        defer { gate.signal() }
        return try body()
    }
}

/// One frame through the whole pipeline: scan -> base reference -> dyes ->
/// print. The app and `flxconvert` both drive this.
final class Converter {
    let printStage: PrintStage
    /// The dye split on the GPU; nil where Metal is missing, and the CPU's
    /// solve, which gives the same, does it.
    let dyeStage: DyeStage?
    private var unmixers: [String: Unmixer] = [:]
    private var flats: [String: FlatField] = [:]
    private let lock = NSLock()

    init() throws {
        printStage = try PrintStage()
        dyeStage = try? DyeStage()
    }

    enum Failure: Error, CustomStringConvertible {
        case noBase(String)
        var description: String {
            switch self { case .noBase(let why): return "no film base to measure against: \(why)" }
        }
    }

    func unmixer(for roll: RollSettings) throws -> Unmixer {
        let key = "\(roll.filmStock)|\(roll.lightCCT)"
        lock.lock(); defer { lock.unlock() }
        if let u = unmixers[key] { return u }
        let u = Unmixer(film: try PackLibrary.shared.pack(roll.filmStock), lightCCT: roll.lightCCT)
        unmixers[key] = u
        return u
    }

    /// The roll's light frame, decoded once.
    func flatField(for roll: RollSettings) throws -> FlatField? {
        guard roll.useFlatField, let path = roll.flatField else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let f = flats[path] { return f }
        let f = try FlatField.load(URL(fileURLWithPath: path))
        flats[path] = f
        return f
    }

    /// A scan as the rest of the pipeline reads it: divided by the roll's
    /// light frame, when it has one that fits. A light frame from another
    /// camera or lens, or of another shape, is not used, and `note` says why;
    /// nil when it was used, or when the roll has none.
    func prepare(_ scan: Scan, url: URL, roll: RollSettings) -> (scan: Scan, used: Bool, note: String?) {
        let flat: FlatField?
        do { flat = try flatField(for: roll) } catch { return (scan, false, "\(error)") }
        guard let flat else { return (scan, false, nil) }
        let name = flat.url.lastPathComponent
        if let light = flat.camera, let here = FlatField.camera(of: url), !light.matches(here) {
            return (scan, false, "\(name) was shot on \(light), this scan on \(here)")
        }
        do { return (try scan.flattened(by: flat), true, nil) } catch { return (scan, false, "\(error)") }
    }

    /// The base reference for a frame: a hand-picked rebate if there is one,
    /// otherwise the field the rebate along the long edges gives.
    func base(for scan: Scan, frame: FrameSettings, field: RebateField?, format: FrameFormat = .thirtyFive) throws -> BaseReference {
        if let pick = frame.rebatePick {
            let v = scan.median(pick)
            guard v.min() > 0 else { throw Failure.noBase("the picked area is black") }
            return .uniform(v)
        }
        if let field { return .field(field) }
        return .field(try RebateField.detect(in: scan, format: format))
    }

    func negative(of scan: Scan, roll: RollSettings, base: BaseReference,
                  part: (origin: CGPoint, frameWidth: Int, frameHeight: Int)? = nil) throws -> [Float] {
        let unmixer = try unmixer(for: roll)
        if let dyeStage, let cmy = try? dyeStage.negative(of: scan, base: base, unmixer: unmixer, part: part) { return cmy }
        return unmixer.negative(of: scan, base: base, part: part)
    }

    /// The long edge of a raw file at full size, without decoding it: what
    /// the sharpening radius is given in.
    static func nativeLongEdge(_ url: URL) -> Int? {
        if let filter = CIRAWFilter(imageURL: url) {
            let s = filter.nativeSize
            if s.width > 0 { return Int(max(s.width, s.height)) }
        }
        guard let props = RawLoader.metadata(of: url),
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(w, h)
    }

    /// The print of a negative (the frame as scanned), turned, levelled and
    /// cropped by the frame's geometry, linear in `outputColorSpace`.
    /// `detailScale`: the negative's pixels per pixel of the scan at full size.
    func print(negative: [Float], width: Int, height: Int, roll: RollSettings, frame: FrameSettings,
               wholeFrame: Bool = false, forDisplay: Bool = false, detailScale: Double = 1,
               outputColorSpace: String = "sRGB") throws -> PrintStage.Output {
        let recipe = Recipe.forPrint(roll: roll, frame: frame, outputColorSpace: outputColorSpace)
        let setup = try RenderSetupBuilder.build(recipe: recipe, exposureEV: 0)
        return try printStage.print(negative: negative, width: width, height: height, setup: setup, recipe: recipe,
                                    geometry: frame.geometry, wholeFrame: wholeFrame, forDisplay: forDisplay,
                                    detail: frame.detail, detailScale: detailScale)
    }

    /// Decodes, converts and writes one frame; `maxDimension` nil is the
    /// camera's full size. A field fitted on a smaller decode is reused: it is
    /// in frame fractions, as are the crop and the masks.
    func export(_ url: URL, roll: RollSettings, frame: FrameSettings, field: RebateField?,
                to output: URL, format: PrintExporter.Format, maxDimension: Int?,
                outputColorSpace: String = "sRGB", capture: CaptureInfo = CaptureInfo()) throws {
        try FullSize.run {
            try exportNow(url, roll: roll, frame: frame, field: field, to: output, format: format,
                          maxDimension: maxDimension, outputColorSpace: outputColorSpace, capture: capture)
        }
    }

    private func exportNow(_ url: URL, roll: RollSettings, frame: FrameSettings, field: RebateField?,
                           to output: URL, format: PrintExporter.Format, maxDimension: Int?,
                           outputColorSpace: String, capture: CaptureInfo) throws {
        let timing = ProcessInfo.processInfo.environment["FLXCONVERT_TIMING"] == "1"
        var clock = CFAbsoluteTimeGetCurrent(), steps: [String] = []
        func lap(_ name: String) {
            guard timing else { return }
            let now = CFAbsoluteTimeGetCurrent()
            steps.append(String(format: "%@ %.0f (%.1f GB)", name, (now - clock) * 1000, Converter.footprint()))
            clock = now
        }
        defer { if timing { Swift.print("export [\(steps.joined(separator: ", ")) ms]") } }
        // Each stage's input let go as soon as the next has its output: at full
        // size every one of them is 16 bytes a pixel (700 MB for 45 MP).
        let (cmy, width, height): ([Float], Int, Int) = try autoreleasepool {
            let scan: Scan = try autoreleasepool {
                let decoded = try Scan.load(url, maxDimension: maxDimension)
                lap("decode")
                return prepare(decoded, url: url, roll: roll).scan
            }
            lap("flat")
            let base = try self.base(for: scan, frame: frame, field: field, format: roll.format)
            lap("base")
            return (try negative(of: scan, roll: roll, base: base), scan.width, scan.height)
        }
        lap("dyes")
        let full = Converter.nativeLongEdge(url).map { Double(max(width, height)) / Double($0) } ?? 1
        let printed = try autoreleasepool {
            try print(negative: cmy, width: width, height: height, roll: roll, frame: frame,
                      detailScale: min(full, 1), outputColorSpace: outputColorSpace)
        }
        lap("print")
        defer { lap("write") }
        try PrintExporter.write(linear: printed.pixels, width: printed.width, height: printed.height, to: output,
                           format: format, colorSpace: outputColorSpace,
                           metadata: ExportMetadata.properties(source: RawLoader.metadata(of: url),
                                                               print: Converter.printInfo(roll: roll), capture: capture))
    }

    /// A small print of a frame, for the sidebar: the base measured on a
    /// 2048-pixel decode, as the preview measures it, then the dyes split and
    /// the print made at about twice `longEdge`, through the frame's own
    /// shape, masks and settings. Encoded for the screen.
    func thumbnail(_ url: URL, roll: RollSettings, frame: FrameSettings, longEdge: Int = 220) throws -> PrintStage.Output {
        let scan = prepare(try Scan.load(url, maxDimension: 2048), url: url, roll: roll).scan
        let base = try self.base(for: scan, frame: frame, field: nil, format: roll.format)
        let small = scan.reduced(by: max(1, max(scan.width, scan.height) / (2 * longEdge)))
        let cmy = try negative(of: small, roll: roll, base: base)
        let scale = Converter.nativeLongEdge(url).map { Double(max(small.width, small.height)) / Double($0) } ?? 1
        return try print(negative: cmy, width: small.width, height: small.height, roll: roll, frame: frame,
                         forDisplay: true, detailScale: min(scale, 1))
    }

    /// The process's memory footprint in GB, for the timing notes.
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1e9 : 0
    }

    /// The film and the paper a roll prints with, by name, and the film's speed.
    static func printInfo(roll: RollSettings) -> ExportMetadata.Print {
        let film = try? PackLibrary.shared.pack(roll.filmStock)
        let paperStock = roll.printStock ?? film?.targetPrint
        let paper = paperStock.flatMap { try? PackLibrary.shared.pack($0) }?.name ?? paperStock ?? "paper"
        return ExportMetadata.Print(film: film?.name ?? roll.filmStock, paper: paper,
                                    speed: ExportMetadata.speed(stock: roll.filmStock))
    }
}
