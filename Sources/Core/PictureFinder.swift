import Foundation
import CoreGraphics

/// The picture on a scanned negative: the rectangle the camera's gate exposed.
struct PictureFrame: Equatable {
    /// Its corners in fractions of the scan, in order around it: along the
    /// near long edge, then back along the far one.
    var corners: [CGPoint]
    /// How many of the two long edges and of the two frame ends showed. One
    /// that did not is taken at the rebate strip, or where the scan or the
    /// holder ends.
    var longEdgesFound: Int
    var endsFound: Int
    /// What tilt each long edge still had, in degrees, when last measured:
    /// how well the levelling took.
    var residualTilt: [Double] = []
}

/// Finds the picture from the film alone, never from what the picture shows.
///
/// Around the picture the film was never exposed: the rebate along the long
/// edges and the gap between frames are bare base, flat, at the base's own
/// density (a little above it at a fogged end of a roll: 0.14 D on one test frame).
/// The gate's edge is a sharp, straight step from that band into the picture.
/// So, with the scan turned until the rebate strips are level, each edge is
/// where the median over a whole side steps up, inwards, out of a band that is
/// flat across that side and at most 0.2 D over the base. Picture content
/// rarely steps along a whole side at once, and never out of bare base.
///
/// The long edges are looked for from the rebate strips inwards, the frame
/// ends in the outer 35% at either end, so a neighbouring frame or the holder
/// beyond the gap is never taken for the picture. Tuned in pixels at about
/// 2048 on the long side, as `RebateField.detect` is; a bigger scan is
/// measured reduced.
enum PictureFinder {
    enum Failure: Error, CustomStringConvertible {
        case noBase, noPicture
        var description: String {
            switch self {
            case .noBase: return "No film base to measure the picture's edges from: pick the rebate first"
            case .noPicture: return "The picture's edges did not show"
            }
        }
    }

    static func find(in full: Scan, base: BaseReference, field: RebateField?) -> PictureFrame? {
        let scan = full.reduced(by: max(1, Int((Double(max(full.width, full.height)) / 2048).rounded())))
        let sw = scan.width, sh = scan.height
        guard sw > 64, sh > 64 else { return nil }
        let vertical = field?.vertical ?? (sh > sw)
        // Worked with the long edges running along x: w along, h across.
        let w = vertical ? sh : sw, h = vertical ? sw : sh

        // Green density over the base, the long edges along x.
        var density = [Float](repeating: .nan, count: w * h)
        density.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: sh) { y in
                for x in 0..<sw {
                    let g = scan.pixels[(y * sw + x) * 4 + 1]
                    let b = base.log(x: (Double(x) + 0.5) / Double(sw), y: (Double(y) + 0.5) / Double(sh)).y
                    let a = vertical ? y : x, c = vertical ? x : y
                    out[c * w + a] = b - log10(max(g, 1e-6))
                }
            }
        }

        // The rebate strips' tilt and where they cross the middle of the frame.
        var tilt = 0.0
        var nearStrip: Double?, farStrip: Double?
        if let f = field {
            let slope = { (s: RebateField.Strip) in (s.c1 - s.c0) / (s.a1 - s.a0) * Double(h) / Double(w) }
            // A mirrored stand-in for a missing edge leans the other way.
            switch f.onlyEdge {
            case nil: tilt = atan((slope(f.near) + slope(f.far)) / 2)
            case (f.vertical ? "left" : "top")?: tilt = atan(slope(f.near))
            default: tilt = atan(slope(f.far))
            }
            nearStrip = f.near.across(0.5) * Double(h)
            farStrip = f.far.across(0.5) * Double(h)
        }

        var top = 0.0, bottom = Double(h - 1), left = 0.0, right = Double(w - 1)
        var longFound = 0, endsFound = 0
        var level = Level(density, width: w, height: h, tilt: tilt)
        var edgeSlopes: [Double] = []
        for pass in 0..<3 {
            // The long edges, over the middle 70% of the length.
            let along = Int(0.15 * Double(w))..<Int(0.85 * Double(w))
            // From a little outside the strip, in case the rebate finder took a
            // flat band of the picture next to the rebate for it.
            let nearLo = nearStrip.map { Int($0 - 0.05 * Double(h)) } ?? 0
            let nearHi = nearStrip.map { Int($0 + 0.08 * Double(h)) } ?? Int(0.35 * Double(h))
            let farLo = farStrip.map { Int($0 - 0.08 * Double(h)) } ?? Int(0.65 * Double(h))
            let farHi = farStrip.map { Int($0 + 0.05 * Double(h)) + 1 } ?? h
            let t = level.edgeAcross(columns: along, in: nearLo..<nearHi, inward: 1)
            let b = level.edgeAcross(columns: along, in: farLo..<farHi, inward: -1)
            top = t ?? nearStrip.map { $0 + (field?.near.half ?? 0) * Double(h) } ?? 0
            bottom = b ?? farStrip.map { $0 - (field?.far.half ?? 0) * Double(h) } ?? Double(h - 1)
            longFound = (t == nil ? 0 : 1) + (b == nil ? 0 : 1)

            // The frame ends, over the middle 80% of the picture's height.
            let inset = 0.1 * (bottom - top)
            let rows = Int(top + inset)..<max(Int(bottom - inset), Int(top + inset) + 1)
            let l = level.edgeAlong(rows: rows, in: 0..<Int(0.35 * Double(w)), inward: 1)
            let r = level.edgeAlong(rows: rows, in: Int(0.65 * Double(w))..<w, inward: -1)
            left = l ?? level.gapEnd(rows: rows, from: Int(0.35 * Double(w)), outward: -1)
            right = r ?? level.gapEnd(rows: rows, from: Int(0.65 * Double(w)), outward: 1)
            endsFound = (l == nil ? 0 : 1) + (r == nil ? 0 : 1)

            // The strips' tilt, refined from the long edges themselves: where
            // each lies in eight stretches of the picture, through the median
            // of the slopes between every two stretches, so a stretch that
            // caught the soft step a few pixels inside the gate's edge does
            // not lean the line. The steadier edge counts for more.
            guard pass < 2 else { break }
            var fits: [(slope: Double, weight: Double)] = []
            edgeSlopes = []
            for (edge, inward) in [(t, 1), (b, -1)] {
                guard let e = edge else { continue }
                let window = Int(e) - 12..<Int(e) + 13
                var xs: [Double] = [], ys: [Double] = []
                for j in 0..<8 {
                    let a0 = left + (right - left) * (0.04 + 0.92 * Double(j) / 8)
                    let a1 = left + (right - left) * (0.04 + 0.92 * Double(j + 1) / 8)
                    if let y = level.edgeAcross(columns: Int(a0)..<Int(a1), in: window, inward: inward) {
                        xs.append((a0 + a1) / 2); ys.append(y)
                    }
                }
                guard xs.count >= 5 else { continue }
                var pairs: [Float] = []
                for i in xs.indices { for j in xs.indices where j > i { pairs.append(Float((ys[j] - ys[i]) / (xs[j] - xs[i]))) } }
                let slope = Double(Stats.median(pairs))
                let centre = Stats.median(zip(xs, ys).map { Float($0.1 - slope * $0.0) })
                let spread = Stats.median(zip(xs, ys).map { abs(Float($0.1 - slope * $0.0) - centre) })
                fits.append((slope, 1 / (Double(spread * spread) + 0.25)))
                edgeSlopes.append(atan(slope) * 180 / .pi)
            }
            guard !fits.isEmpty else { break }
            let slope = fits.map { $0.slope * $0.weight }.reduce(0, +) / fits.map(\.weight).reduce(0, +)
            tilt += atan(slope)
            level = Level(density, width: w, height: h, tilt: tilt)
        }
        guard right - left > 0.3 * Double(w), bottom - top > 0.3 * Double(h) else { return nil }

        // Back into the scan: turned back by the tilt, and out of the working
        // orientation, as fractions.
        let corners = [(left, top), (right, top), (right, bottom), (left, bottom)].map { p -> CGPoint in
            let s = level.source(x: p.0, y: p.1)
            let x = vertical ? s.y : s.x, y = vertical ? s.x : s.y
            return CGPoint(x: (x + 0.5) / Double(sw), y: (y + 0.5) / Double(sh))
        }
        return PictureFrame(corners: corners, longEdgesFound: longFound, endsFound: endsFound, residualTilt: edgeSlopes)
    }

    /// The density turned so that a line tilted by `tilt` (radians, y down)
    /// lies level, and the medians the edges are read from.
    private struct Level {
        let w: Int, h: Int
        let c: Double, s: Double
        let cx: Double, cy: Double
        var pixels: [Float]

        init(_ density: [Float], width w: Int, height h: Int, tilt: Double) {
            self.w = w; self.h = h
            c = cos(tilt); s = sin(tilt)
            cx = Double(w - 1) / 2; cy = Double(h - 1) / 2
            var out = [Float](repeating: .nan, count: w * h)
            let (c, s, cx, cy) = (c, s, cx, cy)
            out.withUnsafeMutableBufferPointer { o in
                let o = o
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let sx = cx + c * (Double(x) - cx) - s * (Double(y) - cy)
                        let sy = cy + s * (Double(x) - cx) + c * (Double(y) - cy)
                        guard sx >= 0, sy >= 0, sx <= Double(w - 1), sy <= Double(h - 1) else { continue }
                        let x0 = min(Int(sx), w - 2), y0 = min(Int(sy), h - 2)
                        let tx = Float(sx - Double(x0)), ty = Float(sy - Double(y0))
                        let i = y0 * w + x0
                        o[y * w + x] = (density[i] * (1 - tx) + density[i + 1] * tx) * (1 - ty)
                            + (density[i + w] * (1 - tx) + density[i + w + 1] * tx) * ty
                    }
                }
            }
            pixels = out
        }

        /// The unturned point a point of the levelled density came from.
        func source(x: Double, y: Double) -> CGPoint {
            CGPoint(x: cx + c * (x - cx) - s * (y - cy), y: cy + s * (x - cx) + c * (y - cy))
        }

        /// A long edge: a row where the columns `columns` step up, going
        /// `inward` (+1 down, -1 up), out of flat base.
        func edgeAcross(columns: Range<Int>, in window: Range<Int>, inward: Int) -> Double? {
            let cols = Array(max(columns.lowerBound, 0)..<min(columns.upperBound, w))
            return PictureFinder.edge(lines: cols.count, positions: h, in: window, inward: inward, outside: 8) { l, p in
                pixels[p * w + cols[l]]
            }
        }

        /// A frame end: a column where the rows `rows` step up, going
        /// `inward` (+1 right, -1 left), out of flat base.
        func edgeAlong(rows: Range<Int>, in window: Range<Int>, inward: Int) -> Double? {
            let rs = Array(max(rows.lowerBound, 0)..<min(rows.upperBound, h))
            return PictureFinder.edge(lines: rs.count, positions: w, in: window, inward: inward, outside: 12) { l, p in
                pixels[rs[l] * w + p]
            }
        }

        /// A frame end where the picture is too thin at the gap for a step to
        /// show (unexposed right up to it): out from inside the picture, the
        /// first of six columns in a row that are as flat as bare base (from
        /// each row to the fourth one on, a median change under 0.0075 D) and
        /// within 0.15 D of it, or where the film
        /// ends, at the holder (over 1.5 D) or at bare light (0.15 D or more
        /// under the base); the end of the scan if neither comes.
        func gapEnd(rows: Range<Int>, from start: Int, outward: Int) -> Double {
            let rs = Array(max(rows.lowerBound, 0)..<min(rows.upperBound, h))
            var run = 0
            var x = start
            while x >= 0 && x < w {
                let v = rs.compactMap { r -> Float? in let d = pixels[r * w + x]; return d.isNaN ? nil : d }
                if !v.isEmpty {
                    let mid = Stats.median(v)
                    if mid > 1.5 || mid < -0.15 { return Double(x - outward * run) }
                    let changes = (0..<max(rs.count - 4, 0)).compactMap { i -> Float? in
                        let a = pixels[rs[i] * w + x], b = pixels[rs[i + 4] * w + x]
                        return a.isNaN || b.isNaN ? nil : abs(b - a)
                    }
                    if abs(mid) < 0.15, !changes.isEmpty, Stats.median(changes) < 0.0075 {
                        run += 1
                        if run >= 6 { return Double(x - outward * (run - 1)) }
                    } else {
                        run = 0
                    }
                }
                x += outward
            }
            return Double(x - outward)
        }
    }

    /// Searches `window` of `positions` for the step into the picture: the
    /// median over all lines of the change across 6 positions, going
    /// `inward`, at least 0.02 D; the `outside` positions before it flat
    /// (from each line to the fourth one on, a median change of 0.015 D at
    /// most) and within -0.15 to 0.2 D of the base. Of those, the one whose
    /// outside is flattest, as nothing on the film is flatter than bare base;
    /// placed where the median profile is steepest, to a fraction of a
    /// position.
    fileprivate static func edge(lines n: Int, positions m: Int, in window: Range<Int>, inward: Int, outside ow: Int,
                                 value: (Int, Int) -> Float) -> Double? {
        let k = 3
        guard n >= 8 else { return nil }
        func median(_ v: [Float]) -> Float? {
            let f = v.filter { !$0.isNaN }
            return f.isEmpty ? nil : Stats.median(f)
        }
        let first = max(window.lowerBound, k + ow), last = min(window.upperBound, m - k - ow - 1)
        guard first < last else { return nil }
        // Each position's median over the lines, and how flat it is there.
        let lo = max(first - k - ow - 6, 0), hi = min(last + k + ow + 7, m)
        var stats = [SIMD2<Float>](repeating: SIMD2(.nan, .nan), count: hi - lo)
        stats.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: hi - lo) { i in
                let column = (0..<n).map { value($0, lo + i) }
                out[i] = SIMD2(median(column) ?? .nan,
                               median((0..<(n - 4)).map { abs(column[$0 + 4] - column[$0]) }) ?? .nan)
            }
        }
        let level = stats.map(\.x), flatness = stats.map(\.y)
        var best: (p: Int, flat: Float)?
        for p in first..<last {
            let outs = inward > 0 ? (p - k - ow)..<(p - k) : (p + k + 1)..<(p + k + 1 + ow)
            // Bare base: not denser than 0.2 D over it, nor bare light past the
            // film's end, which reads 0.6 D or so under it.
            guard let out = median(outs.map { level[$0 - lo] }), out <= 0.2, out >= -0.15,
                  let flat = median(outs.map { flatness[$0 - lo] }), flat <= 0.015, flat < (best?.flat ?? .infinity),
                  let step = median((0..<n).map { (value($0, p + k) - value($0, p - k)) * Float(inward) }),
                  step >= 0.02 else { continue }
            best = (p, flat)
        }
        guard let p = best?.p else { return nil }
        // The steepest point of the median profile near it, to a fraction.
        func slope(_ q: Int) -> Float {
            guard q - 1 >= lo, q + 1 < hi else { return -.infinity }
            let a = level[q - 1 - lo], b = level[q + 1 - lo]
            return a.isNaN || b.isNaN ? -.infinity : (b - a) / 2 * Float(inward)
        }
        let steepest = ((p - 4)...(p + 4)).max { slope($0) < slope($1) } ?? p
        let g0 = slope(steepest - 1), g1 = slope(steepest), g2 = slope(steepest + 1)
        var offset = 0.0
        if g0.isFinite, g1.isFinite, g2.isFinite, g0 - 2 * g1 + g2 < 0 {
            offset = Double(max(-0.5, min(0.5, 0.5 * (g0 - g2) / (g0 - 2 * g1 + g2))))
        }
        return Double(steepest) + offset
    }
}
