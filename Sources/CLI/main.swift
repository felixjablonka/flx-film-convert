import Foundation
import CoreGraphics
import ImageIO
import simd

// flxconvert: FLX Film Convert from the shell, on the same core as the app.
//
//   flxconvert <scan.raw> <out.jpg|tif|png> --film STOCK [--paper STOCK]
//              [--exposure STOPS] [--grade R] [--filter-y CC] [--filter-m CC]
//              [--pick x0,x1,y0,y1] [--turns N] [--straighten DEG] [--size PX]
//              [--sharpness K] [--radius PX] [--masking 0-1] [--clahe 0-1]
//              [--camera TEXT] [--lens TEXT] [--date YYYY-MM-DD] [--ei N] [--notes TEXT]
//   flxconvert --read-metadata <file>...      what an exported file says about itself
//   flxconvert --grey-ramp --film STOCK [--paper STOCK] [--exposure STOPS]
//
// Without --pick, the base is the rebate along both long edges. --grey-ramp
// prints the stock's own grey axis and reports the print's CIELAB per step.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func numbers(_ text: String) -> [Double] { text.split(separator: ",").compactMap { Double($0) } }

// The engine finds its packs and shader from the working directory: the
// snapshot next to build/. Paths are made absolute first.
let paths = args.prefix(while: { !$0.hasPrefix("--") }).prefix(2)
    .map { URL(fileURLWithPath: $0).standardizedFileURL }
let allPaths = args.prefix(while: { !$0.hasPrefix("--") }).map { URL(fileURLWithPath: $0).standardizedFileURL }
let engineDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("engine")
guard FileManager.default.changeCurrentDirectoryPath(engineDir.path) else { fail("no engine snapshot at \(engineDir.path)") }

guard let film = option("--film") else { fail("--film STOCK is required") }
var roll = RollSettings()
roll.filmStock = film
roll.printStock = option("--paper")
roll.filterY = option("--filter-y").flatMap(Double.init) ?? 0
roll.filterM = option("--filter-m").flatMap(Double.init) ?? 0
roll.flatField = option("--flat").map { URL(fileURLWithPath: $0).standardizedFileURL.path }
var frame = FrameSettings()
frame.exposure = option("--exposure").flatMap(Double.init) ?? 0
frame.grade = option("--grade").flatMap(Double.init)
frame.sharpness = option("--sharpness").flatMap(Double.init) ?? 0
frame.sharpenRadius = option("--radius").flatMap(Double.init) ?? 1
frame.sharpenMasking = option("--masking").flatMap(Double.init) ?? 0
frame.localContrast = option("--clahe").flatMap(Double.init) ?? 0
frame.geometry.quarterTurns = option("--turns").flatMap(Int.init) ?? 0
frame.geometry.setStraighten(option("--straighten").flatMap(Double.init) ?? 0)
var capture = CaptureInfo()
capture.camera = option("--camera") ?? ""
capture.lens = option("--lens") ?? ""
capture.notes = option("--notes") ?? ""
capture.exposureIndex = option("--ei").flatMap(Int.init)
if let d = option("--date") {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
    capture.date = f.date(from: d)
}
if let p = option("--pick").map(numbers), p.count == 4 {
    frame.rebatePick = CGRect(x: p[0], y: p[2], width: p[1] - p[0], height: p[3] - p[2])
}

do {
    let converter = try Converter()
    if args.contains("--grey-ramp") {
        let pack = try PackLibrary.shared.pack(film)
        let curves = pack.normalizedDensityCurves
        let steps = stride(from: -6.0, through: 6.0, by: 0.5).map { $0 }
        var cmy: [Float] = []
        for ev in steps {
            let pos = (Float(ev * log10(2)) - pack.logExposureStart) / pack.logExposureStep
            let i0 = max(0, min(Int(pos.rounded(.down)), Constants.curveSamples - 2)), t = pos - Float(i0)
            for c in 0..<3 { cmy.append(curves[i0 * 3 + c] * (1 - t) + curves[(i0 + 1) * 3 + c] * t) }
            cmy.append(1)
        }
        let rgb = try converter.print(negative: cmy, width: steps.count, height: 1, roll: roll, frame: frame).pixels
        let toXYZ = simd_float3x3(rows: [SIMD3(0.4124564, 0.3575761, 0.1804375),
                                         SIMD3(0.2126729, 0.7151522, 0.0721750),
                                         SIMD3(0.0193339, 0.1191920, 0.9503041)])
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        for (k, ev) in steps.enumerated() {
            let xyz = toXYZ * SIMD3(rgb[k * 4], rgb[k * 4 + 1], rgb[k * 4 + 2]) / SIMD3(0.95047, 1, 1.08883)
            print(String(format: "%+5.1f EV  L* %5.1f  a* %+5.1f  b* %+5.1f", ev,
                         116 * f(xyz.y) - 16, 500 * (f(xyz.x) - f(xyz.y)), 200 * (f(xyz.y) - f(xyz.z))))
        }
        exit(0)
    }
    if args.contains("--check-dyes") {
        // The GPU's solve against the CPU's.
        let stage = try DyeStage()
        let size = option("--size").flatMap(Int.init) ?? 2048
        for url in allPaths {
            let scan = converter.prepare(try Scan.load(url, maxDimension: size), url: url, roll: roll).scan
            guard let field = try? RebateField.detect(in: scan) else { print("\(url.lastPathComponent): no rebate"); continue }
            let unmixer = try converter.unmixer(for: roll)
            var t0 = CFAbsoluteTimeGetCurrent()
            let exact = unmixer.negative(of: scan, base: .field(field))
            let cpuMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            t0 = CFAbsoluteTimeGetCurrent()
            let fast = try stage.negative(of: scan, base: .field(field), unmixer: unmixer)
            let gpuMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            var diffs: [Float] = []
            diffs.reserveCapacity(exact.count / 4 * 3)
            var worst: Float = 0
            for i in stride(from: 0, to: exact.count, by: 4) {
                for c in 0..<3 { let d = abs(exact[i + c] - fast[i + c]); diffs.append(d); worst = max(worst, d) }
            }
            diffs.sort()
            let p = { (q: Double) in diffs[min(diffs.count - 1, Int(Double(diffs.count) * q))] }
            print(String(format: "%@ %dx%d: dyes |GPU - CPU| median %.6f, p99 %.6f, p99.99 %.6f, max %.5f D; CPU %.0f ms, GPU %.0f ms",
                         url.lastPathComponent, scan.width, scan.height, p(0.5), p(0.99), p(0.9999), worst, cpuMs, gpuMs))
        }
        exit(0)
    }
    if args.contains("--read-metadata") {
        // What an exported file says about itself: TIFF, EXIF and IPTC.
        for url in allPaths {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { continue }
            print("== \(url.lastPathComponent)")
            for key in [kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary,
                        kCGImagePropertyExifAuxDictionary] {
                guard let d = props[key] as? [CFString: Any] else { continue }
                for (k, v) in d.sorted(by: { ($0.key as String) < ($1.key as String) }) {
                    print("  \(key):\(k) = \(v)".replacingOccurrences(of: "\n", with: " "))
                }
            }
        }
        exit(0)
    }
    if args.contains("--find-picture") {
        // The picture's corners on each scan, as fractions, and how long finding them took.
        for url in allPaths {
            let prepared = converter.prepare(try Scan.load(url, maxDimension: 2048), url: url, roll: roll)
            let scan = prepared.scan
            guard let field = try? RebateField.detect(in: scan) else { print("\(url.lastPathComponent): no rebate"); continue }
            let t0 = CFAbsoluteTimeGetCurrent()
            let found = PictureFinder.find(in: scan, base: .field(field), field: field)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            guard let p = found else { print(String(format: "%@: no picture (%.0f ms)", url.lastPathComponent, ms)); continue }
            let c = p.corners
            let tilt = atan2(Double(c[1].y - c[0].y) * Double(scan.height), Double(c[1].x - c[0].x) * Double(scan.width)) * 180 / .pi
            print(String(format: "%@: edges %d+%d, tilt %+.2f deg, left %@, corners %@ (%.0f ms)", url.lastPathComponent,
                         p.longEdgesFound, p.endsFound, tilt, p.residualTilt.map { String(format: "%+.3f", $0) }.joined(separator: "/"),
                         c.map { String(format: "%.4f,%.4f", $0.x, $0.y) }.joined(separator: " "), ms))
        }
        exit(0)
    }
    if let out = option("--dump-field").map({ URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: "/")) }),
       let url = paths.first {
        // The decoded scan (RGBA32F) and the base reference fitted to it (log10 RGB per pixel), for analysis:
        // <out>.scan.f32, <out>.base.f32, <out>.size.
        let prepared = converter.prepare(try Scan.load(url, maxDimension: option("--size").flatMap(Int.init) ?? 2048),
                                         url: url, roll: roll)
        if let note = prepared.note { print("flat field not used: \(note)") }
        let scan = prepared.scan
        try scan.pixels.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: out.path + ".scan.f32"))
        try "\(scan.width) \(scan.height)\n".write(toFile: out.path + ".size", atomically: true, encoding: .utf8)
        guard let base = try? converter.base(for: scan, frame: frame, field: nil) else {
            print("no rebate: the scan only"); exit(0)
        }
        var logs = [Float](repeating: 0, count: scan.width * scan.height * 3)
        for y in 0..<scan.height {
            for x in 0..<scan.width {
                let v = base.log(x: (Double(x) + 0.5) / Double(scan.width), y: (Double(y) + 0.5) / Double(scan.height))
                let i = (y * scan.width + x) * 3
                logs[i] = v.x; logs[i + 1] = v.y; logs[i + 2] = v.z
            }
        }
        try logs.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: out.path + ".base.f32"))
        if case .field(let f) = base {
            print(String(format: "field: falloff %.3f D, dome %.3f %.3f %.3f%@", f.falloff, f.dome[0], f.dome[1], f.dome[2],
                         f.onlyEdge.map { ", only the \($0) edge" } ?? ""))
            for (name, s) in [("near", f.near), ("far", f.far)] {
                print(String(format: "strip %@ %.4f %.5f %.4f %.5f %.5f", name, s.a0, s.c0, s.a1, s.c1, s.half))
            }
        }
        exit(0)
    }
    if args.contains("--bench"), let url = paths.first {
        // Each step of a reprint after a print control moves, at preview size.
        func ms(_ t: CFAbsoluteTime) -> String { String(format: "%6.1f ms", (CFAbsoluteTimeGetCurrent() - t) * 1000) }
        var t = CFAbsoluteTimeGetCurrent()
        let scan = try Scan.load(url, maxDimension: 2048)
        print("decode      \(ms(t))  \(scan.width) x \(scan.height)")
        t = CFAbsoluteTimeGetCurrent()
        let base = try converter.base(for: scan, frame: frame, field: nil)
        print("rebate      \(ms(t))")
        t = CFAbsoluteTimeGetCurrent()
        let cmy = try converter.negative(of: scan, roll: roll, base: base)
        print("dyes        \(ms(t))")
        for k in 0..<4 {
            frame.exposure = Double(k) * 0.1
            let recipe = Recipe.forPrint(roll: roll, frame: frame)
            t = CFAbsoluteTimeGetCurrent()
            let setup = try RenderSetupBuilder.build(recipe: recipe, exposureEV: 0)
            let setupTime = ms(t)
            t = CFAbsoluteTimeGetCurrent()
            let out = try converter.printStage.print(negative: cmy, width: scan.width, height: scan.height,
                                                     setup: setup, recipe: recipe, geometry: frame.geometry, forDisplay: true)
            let printTime = ms(t)
            print("reprint \(k): setup \(setupTime)   print \(printTime)   (\(out.width) x \(out.height))")
        }
        exit(0)
    }
    guard paths.count == 2 else { fail("usage: flxconvert <scan> <output> --film STOCK [options]") }
    let format: PrintExporter.Format
    switch paths[1].pathExtension.lowercased() {
    case "tif", "tiff": format = .tiff16
    case "png": format = .png
    default: format = .jpeg
    }
    let clock = CFAbsoluteTimeGetCurrent()
    try converter.export(paths[0], roll: roll, frame: frame, field: nil, to: paths[1], format: format,
                         maxDimension: option("--size").flatMap(Int.init), capture: capture)
    print(String(format: "%@ -> %@ (%.1f s)", paths[0].lastPathComponent, paths[1].path, CFAbsoluteTimeGetCurrent() - clock))
} catch {
    fail("error: \(error)")
}
