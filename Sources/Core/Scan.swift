import Foundation
import CoreGraphics
import simd

// FLX Film Convert's half of the pipeline: a camera scan of a negative turned
// into the negative's own dye densities, which FLX Film Lab's print stage then
// prints (PrintStage.swift). Nothing here looks at the picture to decide a
// colour: the film base, seen in the rebate, is the only reference.

/// A camera scan, decoded as FLX Film Lab decodes a raw file (linear
/// Rec.2020), at a fixed D65 balance: the rebate takes the scanning light's
/// colour out, so all that matters is that the balance is fixed.
struct Scan {
    let width: Int
    let height: Int
    let pixels: [Float]          // RGBA32F, row-major

    static let rawExtensions: Set<String> = ["nef", "nrw", "cr2", "cr3", "crw", "arw", "srf", "sr2", "raf",
                                             "orf", "rw2", "rwl", "pef", "dng", "3fr", "fff", "iiq", "srw", "x3f"]

    static func load(_ url: URL, maxDimension: Int?) throws -> Scan {
        let d = try RawLoader.load(url: url, options: RawLoader.Options(whiteBalance: .daylight,
                                                                        maxDimension: maxDimension))
        return Scan(width: d.width, height: d.height, pixels: d.pixels)
    }

    /// The pixels of `r` (whole pixels, inside the scan) as a scan of their own.
    func cropped(to r: (x: Int, y: Int, width: Int, height: Int)) -> Scan {
        var out = [Float](repeating: 0, count: r.width * r.height * 4)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<r.height {
                    dst.baseAddress!.advanced(by: y * r.width * 4)
                        .update(from: src.baseAddress!.advanced(by: ((r.y + y) * width + r.x) * 4), count: r.width * 4)
                }
            }
        }
        return Scan(width: r.width, height: r.height, pixels: out)
    }

    /// The scan box-filtered down by a whole factor, for measuring at the
    /// size the rebate finder is tuned for.
    func reduced(by k: Int) -> Scan {
        guard k > 1 else { return self }
        let w = width / k, h = height / k
        var out = [Float](repeating: 0, count: w * h * 4)
        let px = pixels, width = self.width
        out.withUnsafeMutableBufferPointer { o in
            let o = o
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    var acc = SIMD4<Float>(repeating: 0)
                    for dy in 0..<k {
                        for dx in 0..<k {
                            let i = ((y * k + dy) * width + x * k + dx) * 4
                            acc += SIMD4(px[i], px[i + 1], px[i + 2], px[i + 3])
                        }
                    }
                    acc /= Float(k * k)
                    let d = (y * w + x) * 4
                    o[d] = acc.x; o[d + 1] = acc.y; o[d + 2] = acc.z; o[d + 3] = acc.w
                }
            }
        }
        return Scan(width: w, height: h, pixels: out)
    }

    /// Per-channel median over a rectangle given as fractions of the frame,
    /// sampled to at most about 40,000 pixels.
    func median(_ r: CGRect) -> SIMD3<Float> {
        let x0 = max(Int(r.minX * Double(width)), 0), x1 = min(Int(r.maxX * Double(width)), width)
        let y0 = max(Int(r.minY * Double(height)), 0), y1 = min(Int(r.maxY * Double(height)), height)
        guard x1 > x0, y1 > y0 else { return SIMD3(repeating: 0) }
        let step = max(1, Int(sqrt(Double((x1 - x0) * (y1 - y0)) / 40_000)))
        var c: [[Float]] = [[], [], []]
        for y in stride(from: y0, to: y1, by: step) {
            for x in stride(from: x0, to: x1, by: step) {
                let i = (y * width + x) * 4
                c[0].append(pixels[i]); c[1].append(pixels[i + 1]); c[2].append(pixels[i + 2])
            }
        }
        return SIMD3(Stats.median(c[0]), Stats.median(c[1]), Stats.median(c[2]))
    }
}

enum Stats {
    static func median(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(); return s[s.count / 2]
    }
    static func percentile(_ v: [Float], _ p: Double) -> Float {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(); return s[min(Int(Double(s.count - 1) * p), s.count - 1)]
    }
    static func polyfit(_ xs: [Double], _ ys: [Double], degree: Int) -> [Double] {
        let k = degree + 1
        var a = [Double](repeating: 0, count: k * k), b = [Double](repeating: 0, count: k)
        for (x, y) in zip(xs, ys) {
            var p = [Double](repeating: 1, count: k)
            for j in 1..<k { p[j] = p[j - 1] * x }
            for r in 0..<k {
                b[r] += p[r] * y
                for c in 0..<k { a[r * k + c] += p[r] * p[c] }
            }
        }
        for col in 0..<k {                              // Gaussian elimination, partial pivoting
            let pivot = (col..<k).max { abs(a[$0 * k + col]) < abs(a[$1 * k + col]) }!
            if pivot != col {
                for c in 0..<k { a.swapAt(col * k + c, pivot * k + c) }
                b.swapAt(col, pivot)
            }
            guard abs(a[col * k + col]) > 1e-12 else { continue }
            for r in (col + 1)..<k {
                let f = a[r * k + col] / a[col * k + col]
                for c in col..<k { a[r * k + c] -= f * a[col * k + c] }
                b[r] -= f * b[col]
            }
        }
        var coef = [Double](repeating: 0, count: k)
        for r in stride(from: k - 1, through: 0, by: -1) {
            var s = b[r]
            for c in (r + 1)..<k { s -= a[r * k + c] * coef[c] }
            coef[r] = abs(a[r * k + r]) > 1e-12 ? s / a[r * k + r] : 0
        }
        return coef
    }
    static func polyval(_ coef: [Double], _ x: Double) -> Double { coef.reversed().reduce(0) { $0 * x + $1 } }
    /// Least squares: the coefficients that best give y from the rows.
    static func lstsq(_ rows: [[Double]], _ y: [Double]) -> [Double] {
        guard let k = rows.first?.count else { return [] }
        var a = [Double](repeating: 0, count: k * k), b = [Double](repeating: 0, count: k)
        for (p, v) in zip(rows, y) {
            for r in 0..<k {
                b[r] += p[r] * v
                for c in 0..<k { a[r * k + c] += p[r] * p[c] }
            }
        }
        for col in 0..<k {
            let pivot = (col..<k).max { abs(a[$0 * k + col]) < abs(a[$1 * k + col]) }!
            if pivot != col {
                for c in 0..<k { a.swapAt(col * k + c, pivot * k + c) }
                b.swapAt(col, pivot)
            }
            guard abs(a[col * k + col]) > 1e-12 else { continue }
            for r in (col + 1)..<k {
                let f = a[r * k + col] / a[col * k + col]
                for c in col..<k { a[r * k + c] -= f * a[col * k + c] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: k)
        for r in stride(from: k - 1, through: 0, by: -1) {
            var t = b[r]
            for c in (r + 1)..<k { t -= a[r * k + c] * x[c] }
            x[r] = abs(a[r * k + r]) > 1e-12 ? t / a[r * k + r] : 0
        }
        return x
    }
}

// MARK: - The base reference

/// The film base's brightness at every point of the scan, as log10 per
/// channel: what a pixel's densities are measured against.
enum BaseReference: Equatable {
    /// The rebate along both long edges: the light's falloff and colour come
    /// out with the base.
    case field(RebateField)
    /// One rebate value, picked by hand: right where it was picked, off by
    /// the scan's falloff elsewhere.
    case uniform(SIMD3<Float>)

    func log(x: Double, y: Double) -> SIMD3<Float> {
        switch self {
        case .field(let f): return f.baseLog(x: x, y: y)
        case .uniform(let v): return SIMD3(log10(max(v.x, 1e-6)), log10(max(v.y, 1e-6)), log10(max(v.z, 1e-6)))
        }
    }
}

/// The rebate is one density everywhere, so how bright it scans along two
/// opposite edges is how the scanning light falls there, channel by channel.
/// Fitted along each edge and interpolated across, with the lift a radial
/// falloff gives between the edges, it is the base's brightness everywhere.
///
/// The strips are the rebate along the long edges or, where neither long edge
/// shows clean rebate, the gaps between frames at the short ends, which are
/// unexposed film too. Coordinates are fractions of the frame: "along" runs
/// with the strips, "across" from one to the other, so a portrait scan works
/// as a landscape one does.
struct RebateField: Codable, Equatable {
    /// A strip of rebate: the line through (a0, c0) and (a1, c1), +- half.
    struct Strip: Codable, Equatable {
        var a0, c0, a1, c1, half: Double
        func across(_ a: Double) -> Double { c0 + (c1 - c0) * (a - a0) / (a1 - a0) }
    }

    var vertical: Bool          // the strips run top to bottom
    var near: Strip             // the strip at across 0 (top, or left)
    var far: Strip              // the strip at across 1
    var span: [Double]          // the along range the fits cover
    var nearFit: [[Double]]     // log10 brightness per channel, quartic in u = -1...1 over span
    var farFit: [[Double]]
    var dome: [Double]          // per channel, log10 per (across fraction)^2
    /// How much the base's brightness varies over the frame, green, in D.
    var falloff: Double
    /// Set when only one edge showed clean rebate: its fit stands in for the
    /// other's, and the other strip, drawn parallel to it on the far side, is
    /// not a measurement.
    var onlyEdge: String?
    /// The edges the strips lie along: the long edges' rebate, or the gaps
    /// between frames at the short ends.
    enum Edges: String, Codable { case long, short }
    var edges: Edges = .long

    var nearName: String { vertical ? "left" : "top" }
    var farName: String { vertical ? "right" : "bottom" }

    func baseLog(x: Double, y: Double) -> SIMD3<Float> {
        let a = vertical ? y : x, c = vertical ? x : y
        let u = min(max((a - span[0]) / (span[1] - span[0]), 0), 1) * 2 - 1
        let cn = near.across(a), cf = far.across(a)
        let cc = min(max(c, cn), cf)
        let t = (cc - cn) / max(cf - cn, 1e-6)
        var out = SIMD3<Float>()
        for ch in 0..<3 {
            out[ch] = Float(Stats.polyval(nearFit[ch], u) * (1 - t) + Stats.polyval(farFit[ch], u) * t
                            + dome[ch] * (cc - cn) * (cf - cc))
        }
        return out
    }

    /// The strips measured, as line segments in frame fractions, for drawing:
    /// a stand-in for an edge that showed none is left out.
    func stripLines() -> [(CGPoint, CGPoint, Double)] {
        let measured = onlyEdge == nil ? [near, far] : onlyEdge == nearName ? [near] : [far]
        return measured.map { s in
            let p0 = vertical ? CGPoint(x: s.across(span[0]), y: span[0]) : CGPoint(x: span[0], y: s.across(span[0]))
            let p1 = vertical ? CGPoint(x: s.across(span[1]), y: span[1]) : CGPoint(x: span[1], y: s.across(span[1]))
            return (p0, p1, s.half)
        }
    }
}

extension RebateField {
    enum Failure: Error, CustomStringConvertible {
        case noRebate(String)
        var description: String {
            switch self {
            case .noRebate(let which): return "no clean rebate found along the \(which) edge, nor in a gap between frames"
            }
        }
    }

    /// Finds the rebate strips along both long edges and fits the field; where
    /// neither long edge shows clean rebate, the gaps between frames at the
    /// short ends instead.
    static func detect(in full: Scan) throws -> RebateField {
        let scan = reducedForSearch(full)
        let portrait = scan.height > scan.width
        let long = EdgeSearch(scan, vertical: portrait, ends: false, expected: nil)
        if let field = long.field() { return field }
        if let field = EdgeSearch(scan, vertical: !portrait, ends: true, expected: long.baseLevel).field() { return field }
        throw Failure.noRebate(portrait ? "left or right" : "top or bottom")
    }

    /// The gaps between frames alone, whatever the long edges show: for testing.
    static func detectGaps(in full: Scan) -> RebateField? {
        let scan = reducedForSearch(full)
        let portrait = scan.height > scan.width
        let long = EdgeSearch(scan, vertical: portrait, ends: false, expected: nil)
        return EdgeSearch(scan, vertical: !portrait, ends: true, expected: long.baseLevel).field()
    }

    /// Tuned in pixels at about 2048 on the long edge; the field itself is in
    /// frame fractions, so a bigger scan is measured reduced.
    private static func reducedForSearch(_ full: Scan) -> Scan {
        full.reduced(by: max(1, Int((Double(max(full.width, full.height)) / 2048).rounded())))
    }
}

/// The search for rebate along one pair of opposite edges of a scan reduced
/// to about 2048 pixels, in its pixels.
///
/// Per sampled column across an edge, a band of rebate. Along a long edge: in
/// from the holder's dark surround, past the film edge, the first band is the
/// run of rows that changes only gradually (the falloff) and ends in a step.
/// That band is rebate, unless the column crosses a sprocket hole: holes show
/// among the columns as a second, much brighter level of that first band
/// (bare light), and those columns are left out. So are columns where the
/// picture is as thin as the base and no step ends the band. At a short end,
/// the gap between frames lies past whatever of the next frame shows: it is
/// the flat run at the rebate's level, as the long edges show it, or else the
/// brightest, since unexposed film is the thinnest the film gets.
///
/// Two strips are then tried on each edge, and the one along which the base
/// follows a smooth falloff in more places is kept. One is the inner half of
/// each column's band, next to the picture, through a line, which follows a
/// scan that is not level. The other is where most columns read the rebate's
/// level, the same distance in from the film's edge everywhere: on black and
/// white film the inner half is often where light spread from a dense part of
/// the picture across the gate's edge fogged the rebate, or where a thin
/// picture runs on at nearly the base's level, and the clean base is further
/// out.
private struct EdgeSearch {
    typealias Strip = RebateField.Strip
    struct Band { var a: Int; var start: Int; var end: Int; var level: Float }
    /// One edge: the profiles in from it, and the band of rebate on each.
    struct Side { var profiles: [(a: Int, p: [Float])] = []; var bands: [Band] = [] }
    struct Found {
        var strip: Strip; var coefs: [[Double]]; var curvature: [Double]; var kept: Int
        /// The bins: where along the strip, their log10 brightness, and which the fit kept.
        var us: [Double] = []; var logs: [SIMD3<Float>] = []; var keep: [Bool] = []
    }

    let scan: Scan
    let vertical: Bool, ends: Bool
    let alongN: Int, acrossN: Int, depth: Int
    let span: [Double]
    private(set) var near = Side(), far = Side()

    init(_ scan: Scan, vertical: Bool, ends: Bool, expected: Float?) {
        self.scan = scan
        self.vertical = vertical
        self.ends = ends
        alongN = vertical ? scan.height : scan.width
        acrossN = vertical ? scan.width : scan.height
        // A gap between frames lies further in than the rebate along an edge.
        depth = ends ? acrossN / 4 : acrossN / 5
        // Along a gap, the long edges' rebate and sprocket holes at either
        // end of it stay out.
        span = ends ? [0.15, 0.85] : [0.08, 0.92]
        near = side(near: true, expected: expected)
        far = side(near: false, expected: expected)
    }

    var nearName: String { vertical ? "left" : "top" }
    var farName: String { vertical ? "right" : "bottom" }

    func green(_ a: Int, _ c: Int) -> Float {
        let x = vertical ? c : a, y = vertical ? a : c
        return scan.pixels[(y * scan.width + x) * 4 + 1]
    }

    func profile(at a: Int, near: Bool) -> [Float] {
        (0..<depth).map { i in
            let c = near ? i : acrossN - 1 - i
            return Stats.median((max(a - 6, 0)...min(a + 6, alongN - 1)).map { green($0, c) })
        }
    }

    func side(near: Bool, expected: Float?) -> Side {
        var s = Side()
        let lo = ends ? span[0] : 0.08, width = ends ? span[1] - span[0] : 0.84
        for k in 0..<64 {
            let a = Int((lo + width * Double(k) / 63) * Double(alongN))
            let p = profile(at: a, near: near)
            s.profiles.append((a, p))
            if let b = ends ? gapBand(p, expected: expected) : firstBand(p) {
                s.bands.append(Band(a: a, start: b.start, end: b.end, level: b.level))
            }
        }
        return s
    }

    /// The first band in from the film edge: rows, and its level.
    func firstBand(_ p: [Float]) -> (start: Int, end: Int, level: Float)? {
        let peak = Stats.percentile(p, 0.95)
        guard peak > 0, let edge = p.firstIndex(where: { $0 > 0.3 * peak }) else { return nil }
        let start = edge + 3
        var end = start + 4
        guard end < p.count - 2 else { return nil }
        while end < p.count - 2 {
            let ref = Stats.median(Array(p[(end - 4)..<end]))
            if abs(p[end] / ref - 1) > 0.06 && abs(p[end + 1] / ref - 1) > 0.06 { break }
            end += 1
        }
        guard end - start >= 6, end - start <= acrossN * 8 / 100 else { return nil }
        return (start, end, Stats.median(Array(p[start..<end])))
    }

    /// The gap between frames on a profile in from a short end.
    func gapBand(_ p: [Float], expected: Float?) -> (start: Int, end: Int, level: Float)? {
        let runs = plateaus(p)
        guard let e = expected else { return runs.max { $0.level < $1.level } }
        func off(_ r: (start: Int, end: Int, level: Float)) -> Float { abs(log10(r.level / e)) }
        return runs.filter { off($0) < 0.12 }.min { off($0) < off($1) }
    }

    /// Runs of at least 8 values that stay within 5% of their own median,
    /// each with its level.
    func plateaus(_ p: [Float]) -> [(start: Int, end: Int, level: Float)] {
        var out: [(start: Int, end: Int, level: Float)] = []
        let dark = 0.05 * Stats.percentile(p, 0.95)
        var i = 0
        while i < p.count - 8 {
            guard p[i] > dark else { i += 1; continue }
            var end = i + 1, level = p[i]
            while end < p.count {
                let next = end + 1 < p.count ? p[end + 1] : p[end]
                if abs(p[end] / level - 1) > 0.05 && abs(next / level - 1) > 0.05 { break }
                end += 1
                if (end - i) % 4 == 0 { level = Stats.median(Array(p[i..<end])) }
            }
            if end - i >= 8, end - i <= acrossN * 8 / 100 {
                out.append((i, end, Stats.median(Array(p[i..<end]))))
            }
            i = max(end, i + 1)
        }
        return out
    }

    /// The bands that are rebate, not bare light through a sprocket hole:
    /// without holes the levels are one population.
    func rebateBands(_ s: Side) -> [Band] {
        guard s.bands.count >= 10 else { return [] }
        let floor = Stats.percentile(s.bands.map(\.level), 0.2)
        return s.bands.filter { $0.level < 1.6 * floor }
    }

    /// The rebate's brightness, green, where the bands show it.
    var baseLevel: Float? {
        let levels = (rebateBands(near) + rebateBands(far)).map(\.level)
        return levels.count >= 8 ? Stats.median(levels) : nil
    }

    /// A line c(a) through the points, refitted without those far off it,
    /// and the points it kept.
    func line(_ pts: [(a: Double, c: Double)]) -> (coefs: [Double], kept: [Int])? {
        guard pts.count >= 8 else { return nil }
        var keep = pts.indices.map { _ in true }
        var line = [0.0, 0.0]
        for pass in 0..<2 {
            let idx = pts.indices.filter { keep[$0] }
            line = Stats.polyfit(idx.map { pts[$0].a }, idx.map { pts[$0].c }, degree: 1)
            if pass == 0 {
                let res = pts.map { abs($0.c - Stats.polyval(line, $0.a)) }
                let mad = Double(Stats.median(res.map(Float.init)))
                keep = res.map { $0 < max(3, 2.5 * mad) }
            }
        }
        let kept = pts.indices.filter { keep[$0] }
        return kept.count >= 6 ? (line, kept) : nil
    }

    /// The strip across the frame for rows i(a) in from the edge (+- half).
    func strip(near: Bool, rows: (Double) -> Double, half: Double) -> Strip {
        func c(_ f: Double) -> Double {
            let i = rows(f * Double(alongN))
            return (near ? i : Double(acrossN - 1) - i) / Double(acrossN)
        }
        return Strip(a0: 0.1, c0: c(0.1), a1: 0.9, c1: c(0.9), half: half / Double(acrossN))
    }

    /// The inner half of each column's band, through a line.
    func innerStrip(_ s: Side, near: Bool) -> Strip? {
        var pts: [(a: Double, c: Double)] = [], halves: [Float] = []
        for b in rebateBands(s) {
            let lo = Double(b.start) + 0.5 * Double(b.end - b.start), hi = Double(b.end) - 2
            guard hi - lo >= 2 else { continue }
            pts.append((Double(b.a), (lo + hi) / 2))
            halves.append(Float((hi - lo) / 2))
        }
        guard let line = line(pts) else { return nil }
        let half = max(2, Double(Stats.percentile(line.kept.map { halves[$0] }, 0.25)))
        return strip(near: near, rows: { Stats.polyval(line.coefs, $0) }, half: half)
    }

    /// Where most columns read the rebate's level, the same distance in from
    /// the film's edge (or the holder's, where it covers the film's) everywhere.
    func levelStrip(_ s: Side, near: Bool) -> Strip? {
        let bands = rebateBands(s)
        guard bands.count >= 8 else { return nil }
        // The level, log10, as a quadratic along the edge, refitted without the
        // bands well below it (fogged) or above it.
        let xs = bands.map { Double($0.a) / Double(alongN) }
        let ys = bands.map { Double(log10($0.level)) }
        var keep = xs.indices.map { _ in true }
        var level = [0.0, 0.0, 0.0]
        for pass in 0..<3 {
            let idx = xs.indices.filter { keep[$0] }
            guard idx.count >= 6 else { return nil }
            level = Stats.polyfit(idx.map { xs[$0] }, idx.map { ys[$0] }, degree: 2)
            if pass < 2 {
                keep = xs.indices.map { i in
                    let r = ys[i] - Stats.polyval(level, xs[i])
                    return r > -0.013 && r < 0.02
                }
            }
        }
        // Where each band starts, holes' too: the edge it is measured from.
        guard let edge = line(s.bands.map { (Double($0.a), Double($0.start)) })?.coefs else { return nil }
        let reach = acrossN * 8 / 100
        var count = [Int](repeating: 0, count: reach)
        for (a, p) in s.profiles {
            let expected = Stats.polyval(level, Double(a) / Double(alongN))
            let o = Stats.polyval(edge, Double(a))
            for r in 0..<reach {
                let i = Int((o + Double(r)).rounded())
                guard i >= 0, i < p.count, p[i] > 0 else { continue }
                if abs(Double(log10(p[i])) - expected) < 0.017 { count[r] += 1 }
            }
        }
        let share = count.map { Double($0) / Double(max(s.profiles.count, 1)) }
        guard let peak = share.max(), peak >= 0.5, let at = share.firstIndex(of: peak) else { return nil }
        let cut = max(0.4, 0.7 * peak)
        var r0 = at, r1 = at
        while r0 > 0, share[r0 - 1] >= cut { r0 -= 1 }
        while r1 < reach - 1, share[r1 + 1] >= cut { r1 += 1 }
        // A row in from either side, off the transitions.
        let lo = Double(r0) + 1, hi = Double(r1) - 1
        guard hi - lo >= 2 else { return nil }
        return strip(near: near, rows: { Stats.polyval(edge, $0) + (lo + hi) / 2 }, half: (hi - lo) / 2)
    }

    /// log10 brightness along a strip, per channel, through 40 bins, with the
    /// curvature along it, per pixel squared, and how many bins it kept. Bins
    /// far off their neighbours (a sprocket hole, a stain) go first, then,
    /// refitting, those the fit shows edge print, dust or fog pulled down, or
    /// flare up: the rebate is the thinnest the film gets, so whatever else is
    /// in it is mostly darker. The fit is a quartic where the bins kept reach
    /// both ends of the edge without gaps, and lower where they do not, so it
    /// does not swing through a gap or past the last bin.
    func fit(_ s: Strip) -> Found? {
        var us: [Double] = [], logs: [SIMD3<Float>] = []
        for b in 0..<40 {
            let lo = span[0] + (span[1] - span[0]) * Double(b) / 40
            let hi = span[0] + (span[1] - span[0]) * Double(b + 1) / 40
            let c = s.across((lo + hi) / 2)
            let r = vertical ? CGRect(x: c - s.half, y: lo, width: 2 * s.half, height: hi - lo)
                             : CGRect(x: lo, y: c - s.half, width: hi - lo, height: 2 * s.half)
            let m = scan.median(r)
            guard m.min() > 0 else { continue }
            us.append(((lo + hi) / 2 - span[0]) / (span[1] - span[0]) * 2 - 1)
            logs.append(SIMD3(log10(m.x), log10(m.y), log10(m.z)))
        }
        guard us.count >= 12 else { return nil }
        // Against the median of the nine bins around each.
        var keep = us.indices.map { i in
            let window = max(0, i - 4)...min(us.count - 1, i + 4)
            return (0..<3).allSatisfy { ch in
                abs(logs[i][ch] - Stats.median(window.map { logs[$0][ch] })) < 0.05
            }
        }
        /// The degree the kept bins support: a quartic where they cover the
        /// edge, a quadratic or a line where they leave gaps or cover less.
        func degree(_ idx: [Int]) -> Int {
            let u = idx.map { us[$0] }
            guard let first = u.first, let last = u.last else { return 1 }
            let gap = zip(u, u.dropFirst()).map { $1 - $0 }.max() ?? 0
            if gap <= 0.3, first <= -0.75, last >= 0.75 { return 4 }
            if gap <= 0.6, last - first >= 0.8 { return 2 }
            return 1
        }
        var coefs: [[Double]] = []
        let bounds: [(Double, Double)] = [(-0.03, 0.04), (-0.012, 0.02), (-0.012, 0.02), (-0.012, 0.02)]
        for pass in 0...bounds.count {
            let idx = us.indices.filter { keep[$0] }
            guard idx.count >= 12 else { return nil }
            let n = degree(idx)
            coefs = (0..<3).map { c in Stats.polyfit(idx.map { us[$0] }, idx.map { Double(logs[$0][c]) }, degree: n) }
            guard pass < bounds.count else { break }
            let (below, above) = bounds[pass]
            keep = us.indices.map { i in
                keep[i] && (0..<3).allSatisfy { ch in
                    let r = Double(logs[i][ch]) - Stats.polyval(coefs[ch], us[i])
                    return r > below && r < above
                }
            }
        }
        let idx = us.indices.filter { keep[$0] }
        guard idx.count >= 12 else { return nil }
        let px = idx.map { (us[$0] + 1) / 2 * (span[1] - span[0]) * Double(alongN) }
        let curvature = (0..<3).map { c in Stats.polyfit(px, idx.map { Double(logs[$0][c]) }, degree: 2)[2] }
        return Found(strip: s, coefs: coefs, curvature: curvature, kept: idx.count, us: us, logs: logs, keep: keep)
    }

    /// The better of the two strips on one edge: the inner half, unless the
    /// rebate's level holds along clearly more of the other.
    func best(_ s: Side, near: Bool) -> Found? {
        let inner = innerStrip(s, near: near).flatMap(fit)
        let level = levelStrip(s, near: near).flatMap(fit)
        if let inner, let level { return level.kept >= inner.kept + 4 ? level : inner }
        return inner ?? level
    }

    /// Both edges' fits together: one shape along the edges, the same for
    /// both, as a falloff about the frame's middle gives, with an offset and a
    /// lean of each edge's own. Where light spread from a dense part of the
    /// picture fogged one edge's rebate all along a stretch, that edge's own
    /// fit follows it down; against the shape the other edge shows, those
    /// bins fall below, and go. Only bins each edge's own fit kept take part.
    func joint(_ n: Found, _ f: Found) -> (Found, Found)? {
        var keepN = n.keep, keepF = f.keep
        var quartic = false
        func row(_ u: Double, near: Bool) -> [Double] {
            (near ? [1, u, 0, 0] : [0, 0, 1, u]) + (quartic ? [u * u, u * u * u, u * u * u * u] : [u * u])
        }
        var params: [[Double]] = []
        for pass in 0..<4 {
            let iN = n.us.indices.filter { keepN[$0] }, iF = f.us.indices.filter { keepF[$0] }
            guard iN.count >= 8, iF.count >= 8 else { return nil }
            let u = (iN.map { n.us[$0] } + iF.map { f.us[$0] }).sorted()
            let gap = zip(u, u.dropFirst()).map { $1 - $0 }.max() ?? 0
            quartic = gap <= 0.3 && u.first! <= -0.75 && u.last! >= 0.75
            let rows = iN.map { row(n.us[$0], near: true) } + iF.map { row(f.us[$0], near: false) }
            params = (0..<3).map { ch in
                Stats.lstsq(rows, iN.map { Double(n.logs[$0][ch]) } + iF.map { Double(f.logs[$0][ch]) })
            }
            guard pass < 3 else { break }
            func fits(_ x: Found, _ i: Int, near: Bool) -> Bool {
                let r = row(x.us[i], near: near)
                return (0..<3).allSatisfy { ch in
                    let d = Double(x.logs[i][ch]) - zip(r, params[ch]).map(*).reduce(0, +)
                    return d > -0.012 && d < 0.02
                }
            }
            keepN = n.us.indices.map { keepN[$0] && fits(n, $0, near: true) }
            keepF = f.us.indices.map { keepF[$0] && fits(f, $0, near: false) }
        }
        let iN = n.us.indices.filter { keepN[$0] }, iF = f.us.indices.filter { keepF[$0] }
        let shape = { (ch: Int) in Array(params[ch][4...]) }
        // Each edge as a polynomial in u: its offset and lean, then the shape.
        let nearCoefs = (0..<3).map { [params[$0][0], params[$0][1]] + shape($0) }
        let farCoefs = (0..<3).map { [params[$0][2], params[$0][3]] + shape($0) }
        let all = (iN.map { n.us[$0] } + iF.map { f.us[$0] })
        // The curvature along the edges, per pixel squared, from the shape.
        let px = all.map { ($0 + 1) / 2 * (span[1] - span[0]) * Double(alongN) }
        let curvature = (0..<3).map { ch in
            Stats.polyfit(px, all.map { Stats.polyval([0, 0] + shape(ch), $0) }, degree: 2)[2]
        }
        var nn = n, ff = f
        (nn.coefs, nn.curvature, nn.keep, nn.kept) = (nearCoefs, curvature, keepN, iN.count)
        (ff.coefs, ff.curvature, ff.keep, ff.kept) = (farCoefs, curvature, keepF, iF.count)
        return (nn, ff)
    }

    func field() -> RebateField? {
        var n = best(near, near: true), f = best(far, near: false)
        if let nn = n, let ff = f, let both = joint(nn, ff) { (n, f) = both }
        // A stand-in for a missing edge: the found strip turned half a turn
        // about the frame's centre, so it runs parallel, with the same fit.
        func turned(_ s: Strip) -> Strip { Strip(a0: s.a0, c0: 1 - s.c1, a1: s.a1, c1: 1 - s.c0, half: s.half) }
        var onlyEdge: String?
        let nearFound: Found, farFound: Found
        switch (n, f) {
        case let (n?, f?): (nearFound, farFound) = (n, f)
        case let (n?, nil):
            (nearFound, farFound) = (n, Found(strip: turned(n.strip), coefs: n.coefs, curvature: n.curvature, kept: 0))
            onlyEdge = nearName
        case let (nil, f?):
            (nearFound, farFound) = (Found(strip: turned(f.strip), coefs: f.coefs, curvature: f.curvature, kept: 0), f)
            onlyEdge = farName
        case (nil, nil): return nil
        }
        // Between the strips the light is brighter than a straight line from
        // one to the other: for a radial falloff, by k (c - cNear)(cFar - c),
        // with k the curvature measured along the strips.
        let dome = (0..<3).map { -(nearFound.curvature[$0] + farFound.curvature[$0]) / 2 * Double(acrossN * acrossN) }
        var field = RebateField(vertical: vertical, near: nearFound.strip, far: farFound.strip, span: span,
                                nearFit: nearFound.coefs, farFit: farFound.coefs, dome: dome, falloff: 0,
                                onlyEdge: onlyEdge, edges: ends ? .short : .long)
        var lo: Float = 9, hi: Float = -9
        for i in 0...20 {
            for j in 0...20 {
                let g = field.baseLog(x: 0.05 + 0.9 * Double(i) / 20, y: 0.05 + 0.9 * Double(j) / 20).y
                lo = min(lo, g); hi = max(hi, g)
            }
        }
        field.falloff = Double(hi - lo)
        return field
    }
}

// MARK: - Dyes

/// Turns a scan's densities above the base into the film's dye amounts, the
/// engine's CMY densities above base: the amounts whose spectral density,
/// seen through the decode's colour matching functions under the scanning
/// light behind the stock's own base, gives exactly the densities measured.
/// One Newton solve per pixel, from the stock's own dye spectra.
final class Unmixer {
    let film: ProfilePack
    let n: Int
    let weight: [Float]       // light x base x sensitivity, per channel, summing to 1
    let dye: [Float]          // dye j's density at valid wavelength i
    /// Density each channel sees per unit of each dye, at the base.
    let seen: simd_float3x3
    let seenInverse: simd_float3x3

    /// The decode's spectral sensitivities: Core Image's camera-to-XYZ, then
    /// XYZ -> linear Rec.2020, so the colour matching functions through it.
    static let xyzTo2020 = simd_float3x3(rows: [SIMD3(1.7166512, -0.3556708, -0.2533663),
                                                SIMD3(-0.6666844, 1.6164812, 0.0157685),
                                                SIMD3(0.0176399, -0.0427706, 0.9421031)])

    /// A broadband white scanning light. Its colour comes out with the
    /// rebate; its temperature changes the dye reading only in the second
    /// order (2800-6500 K print almost the same).
    init(film: ProfilePack, lightCCT: Double = 5000) {
        self.film = film
        let shared = PackLibrary.shared.shared_
        func planck(_ nm: Float) -> Float {
            let l = Double(nm) * 1e-9
            return Float(1 / (pow(l, 5) * (exp(1.4388e-2 / (l * lightCCT)) - 1)))
        }
        let light = shared.wavelengths.map(planck)
        let valid = (0..<Constants.wavelengths).filter { film.spectralValid[$0] != 0 }
        let n = valid.count
        var w = [Float](repeating: 0, count: 3 * n), d = [Float](repeating: 0, count: 3 * n)
        let m = Unmixer.xyzTo2020
        for (i, l) in valid.enumerated() {
            let behindBase = light[l] * pow(10, -(film.baseDensity.isEmpty ? 0 : film.baseDensity[l]))
            for c in 0..<3 {
                let s = m[0][c] * shared.cmfs[l * 3] + m[1][c] * shared.cmfs[l * 3 + 1] + m[2][c] * shared.cmfs[l * 3 + 2]
                w[c * n + i] = behindBase * s
                d[c * n + i] = film.channelDensity[l * 3 + c]
            }
        }
        for c in 0..<3 {
            let total = (0..<n).reduce(Float(0)) { $0 + w[c * n + $1] }
            for i in 0..<n { w[c * n + i] /= total }
        }
        var s = simd_float3x3()
        for c in 0..<3 {
            for j in 0..<3 { s[j][c] = (0..<n).reduce(Float(0)) { $0 + w[c * n + $1] * d[j * n + $1] } }
        }
        self.n = n; weight = w; dye = d; seen = s
        seenInverse = film.isMonochrome ? matrix_identity_float3x3 : s.inverse
    }

    func dyes(_ d: SIMD3<Float>, _ e: inout [Float]) -> SIMD3<Float> {
        if film.isMonochrome {
            // One silver layer carried as three identical channels: one amount.
            let rows = SIMD3((0..<3).map { c in seen[0][c] + seen[1][c] + seen[2][c] })
            let x = ((d / rows).sum()) / 3
            return SIMD3(repeating: x)
        }
        var x = seenInverse * d
        for _ in 0..<8 {
            for i in 0..<n { e[i] = exp(-2.302585 * (x.x * dye[i] + x.y * dye[n + i] + x.z * dye[2 * n + i])) }
            var g = SIMD3<Float>(repeating: 0)
            var h = simd_float3x3()
            for c in 0..<3 {
                var gc: Float = 0, h0: Float = 0, h1: Float = 0, h2: Float = 0
                for i in 0..<n {
                    let we = weight[c * n + i] * e[i]
                    gc += we; h0 += we * dye[i]; h1 += we * dye[n + i]; h2 += we * dye[2 * n + i]
                }
                gc = max(gc, 1e-8)
                g[c] = gc
                h[0][c] = h0 / gc; h[1][c] = h1 / gc; h[2][c] = h2 / gc
            }
            let step = h.inverse * (SIMD3(log10(g.x), log10(g.y), log10(g.z)) + d)
            x = simd_clamp(x + step, SIMD3(repeating: -0.5), SIMD3(repeating: 4))
            if simd_length(step) < 1e-5 { break }
        }
        return x
    }

    /// The scan as the negative's dye densities (RGBA32F), each pixel against
    /// the base's brightness at its own position. `part`, when given, says the
    /// scan is the part of a bigger frame starting at `origin`, so the base
    /// (in frame fractions) is read where each pixel lies in the whole.
    func negative(of scan: Scan, base: BaseReference,
                  part: (origin: CGPoint, frameWidth: Int, frameHeight: Int)? = nil) -> [Float] {
        let w = scan.width, h = scan.height
        let fw = Double(part?.frameWidth ?? w), fh = Double(part?.frameHeight ?? h)
        let ox = Double(part?.origin.x ?? 0), oy = Double(part?.origin.y ?? 0)
        var out = [Float](repeating: 0, count: w * h * 4)
        let px = scan.pixels
        out.withUnsafeMutableBufferPointer { o in
            let o = o
            DispatchQueue.concurrentPerform(iterations: h) { y in
                var e = [Float](repeating: 0, count: n)
                let yf = (oy + Double(y) + 0.5) / fh
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let ref = base.log(x: (ox + Double(x) + 0.5) / fw, y: yf)
                    let d = ref - SIMD3(log10(max(px[i], 1e-6)), log10(max(px[i + 1], 1e-6)), log10(max(px[i + 2], 1e-6)))
                    let v = dyes(simd_clamp(d, SIMD3(repeating: -0.5), SIMD3(repeating: 4)), &e)
                    o[i] = v.x; o[i + 1] = v.y; o[i + 2] = v.z; o[i + 3] = 1
                }
            }
        }
        return out
    }
}
