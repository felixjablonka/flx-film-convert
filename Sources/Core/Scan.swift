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

/// The rebate is one density everywhere, so how bright it scans along the two
/// long edges is how the scanning light falls there, channel by channel.
/// Fitted along each edge and interpolated across, with the lift a radial
/// falloff gives between the edges, it is the base's brightness everywhere.
///
/// Coordinates are fractions of the frame: "along" runs with the long edges,
/// "across" from one edge to the other, so a portrait scan works too.
struct RebateField: Codable, Equatable {
    /// A strip of rebate: the line through (a0, c0) and (a1, c1), +- half.
    struct Strip: Codable, Equatable {
        var a0, c0, a1, c1, half: Double
        func across(_ a: Double) -> Double { c0 + (c1 - c0) * (a - a0) / (a1 - a0) }
    }

    var vertical: Bool          // the long edges run top to bottom
    var near: Strip             // the edge at across 0 (top, or left)
    var far: Strip              // the edge at across 1
    var span: [Double]          // the along range the fits cover
    var nearFit: [[Double]]     // log10 brightness per channel, quartic in u = -1...1 over span
    var farFit: [[Double]]
    var dome: [Double]          // per channel, log10 per (across fraction)^2
    /// How much the base's brightness varies over the frame, green, in D.
    var falloff: Double
    /// Set when only one long edge showed clean rebate: that edge's fit,
    /// mirrored across the frame, stands in for the other.
    var onlyEdge: String?

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

    /// The two strips as line segments in frame fractions, for drawing.
    func stripLines() -> [(CGPoint, CGPoint, Double)] {
        [near, far].map { s in
            let p0 = vertical ? CGPoint(x: s.across(span[0]), y: span[0]) : CGPoint(x: span[0], y: s.across(span[0]))
            let p1 = vertical ? CGPoint(x: s.across(span[1]), y: span[1]) : CGPoint(x: span[1], y: s.across(span[1]))
            return (p0, p1, s.half)
        }
    }
}

extension RebateField {
    enum Failure: Error, CustomStringConvertible {
        case noEdge(String)
        var description: String {
            switch self { case .noEdge(let which): return "no clean rebate found along the \(which) edge" }
        }
    }

    /// Finds the rebate strips along both long edges and fits the field.
    ///
    /// Per sampled column across an edge: in from the holder's dark surround,
    /// past the film edge, the first band is the run of rows that changes
    /// only gradually (the falloff) and ends in a step. That band is rebate,
    /// unless the column crosses a sprocket hole: holes show among the columns
    /// as a second, much brighter level of that first band (bare light), and
    /// those columns are left out. So are columns where the picture is as thin
    /// as the base and no step ends the band. The strip is the inner half of
    /// the band, next to the picture, and a line through the columns follows a
    /// scan that is not level.
    static func detect(in full: Scan) throws -> RebateField {
        // Tuned in pixels at about 2048 on the long edge; the field itself is
        // in frame fractions, so a bigger scan is measured reduced.
        let scan = full.reduced(by: max(1, Int((Double(max(full.width, full.height)) / 2048).rounded())))
        let vertical = scan.height > scan.width
        let alongN = vertical ? scan.height : scan.width
        let acrossN = vertical ? scan.width : scan.height
        func green(_ a: Int, _ c: Int) -> Float {
            let x = vertical ? c : a, y = vertical ? a : c
            return scan.pixels[(y * scan.width + x) * 4 + 1]
        }
        let depth = acrossN / 5

        func profile(at a: Int, near: Bool) -> [Float] {
            (0..<depth).map { i in
                let c = near ? i : acrossN - 1 - i
                return Stats.median((max(a - 6, 0)...min(a + 6, alongN - 1)).map { green($0, c) })
            }
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

        func strip(near: Bool) -> Strip? {
            var bands: [(a: Int, start: Int, end: Int, level: Float)] = []
            for k in 0..<64 {
                let a = Int((0.08 + 0.84 * Double(k) / 63) * Double(alongN))
                if let b = firstBand(profile(at: a, near: near)) { bands.append((a, b.start, b.end, b.level)) }
            }
            guard bands.count >= 10 else { return nil }
            // Bare light through the holes is several times brighter than the
            // base; without holes the levels are one population.
            let floor = Stats.percentile(bands.map { $0.level }, 0.2)
            let rebate = bands.filter { $0.level < 1.6 * floor }
            var pts: [(a: Double, c: Double, half: Double)] = []
            for b in rebate {
                let lo = Double(b.start) + 0.5 * Double(b.end - b.start), hi = Double(b.end) - 2
                guard hi - lo >= 2 else { continue }
                let mid = (lo + hi) / 2
                pts.append((Double(b.a), near ? mid : Double(acrossN - 1) - mid, (hi - lo) / 2))
            }
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
            let idx = pts.indices.filter { keep[$0] }
            guard idx.count >= 6 else { return nil }
            let half = max(2, Double(Stats.percentile(idx.map { Float(pts[$0].half) }, 0.25)))
            let a0 = 0.1, a1 = 0.9
            return Strip(a0: a0, c0: Stats.polyval(line, a0 * Double(alongN)) / Double(acrossN),
                         a1: a1, c1: Stats.polyval(line, a1 * Double(alongN)) / Double(acrossN),
                         half: half / Double(acrossN))
        }

        let nearName = vertical ? "left" : "top", farName = vertical ? "right" : "bottom"
        let foundNear = strip(near: true), foundFar = strip(near: false)
        let span = [0.08, 0.92]

        /// log10 brightness along one strip, per channel: a quartic in u
        /// through 40 bins, refitted without the bins edge print or dust pulls
        /// away; and the curvature along it, per pixel squared.
        func fit(_ s: Strip, which: String) throws -> (coefs: [[Double]], curvature: [Double]) {
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
            var keep = us.indices.map { _ in true }
            var coefs: [[Double]] = []
            for pass in 0..<2 {
                coefs = (0..<3).map { c in
                    let idx = us.indices.filter { keep[$0] }
                    return Stats.polyfit(idx.map { us[$0] }, idx.map { Double(logs[$0][c]) }, degree: 4)
                }
                if pass == 0 {
                    for i in us.indices {
                        keep[i] = (0..<3).map { abs(Double(logs[i][$0]) - Stats.polyval(coefs[$0], us[i])) }.max()! < 0.015
                    }
                }
            }
            let idx = us.indices.filter { keep[$0] }
            guard idx.count >= 12 else { throw Failure.noEdge(which) }
            let px = idx.map { (us[$0] + 1) / 2 * (span[1] - span[0]) * Double(alongN) }
            let curvature = (0..<3).map { c in Stats.polyfit(px, idx.map { Double(logs[$0][c]) }, degree: 2)[2] }
            return (coefs, curvature)
        }

        func mirrored(_ s: Strip) -> Strip { Strip(a0: s.a0, c0: 1 - s.c0, a1: s.a1, c1: 1 - s.c1, half: s.half) }
        let nearResult = foundNear.flatMap { s in (try? fit(s, which: nearName)).map { (s, $0) } }
        let farResult = foundFar.flatMap { s in (try? fit(s, which: farName)).map { (s, $0) } }
        var onlyEdge: String?
        let nearStrip: Strip, farStrip: Strip
        let nearFit: (coefs: [[Double]], curvature: [Double]), farFit: (coefs: [[Double]], curvature: [Double])
        switch (nearResult, farResult) {
        case let (n?, f?): (nearStrip, nearFit, farStrip, farFit) = (n.0, n.1, f.0, f.1)
        case let (n?, nil): (nearStrip, nearFit, farStrip, farFit) = (n.0, n.1, mirrored(n.0), n.1); onlyEdge = nearName
        case let (nil, f?): (nearStrip, nearFit, farStrip, farFit) = (mirrored(f.0), f.1, f.0, f.1); onlyEdge = farName
        case (nil, nil): throw Failure.noEdge("\(nearName) or \(farName)")
        }
        // Between the strips the light is brighter than a straight line from
        // one to the other: for a radial falloff, by k (c - cNear)(cFar - c),
        // with k the curvature measured along the strips.
        let dome = (0..<3).map { -(nearFit.curvature[$0] + farFit.curvature[$0]) / 2 * Double(acrossN * acrossN) }
        var field = RebateField(vertical: vertical, near: nearStrip, far: farStrip, span: span,
                                nearFit: nearFit.coefs, farFit: farFit.coefs, dome: dome, falloff: 0, onlyEdge: onlyEdge)
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
