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
/// beyond the gap is never taken for the picture. On roll film, whose frames
/// fill only part of a scan, anywhere along it, the ends are looked for from
/// the gaps between frames inwards, one frame's length (the format's, give or
/// take 12%) apart. Where a holder covers the film's edge
/// (a 120 carrier often leaves no rebate, or a sliver), the long edge is where
/// the holder's opaque band ends, or the sliver of rebate inside it. Tuned in
/// pixels at about 2048 on the long side, as `RebateField.detect` is; a bigger
/// scan is measured reduced.
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

    static func find(in full: Scan, base: BaseReference, field: RebateField?,
                     format: FrameFormat = .thirtyFive) -> PictureFrame? {
        let scan = full.reduced(by: max(1, Int((Double(max(full.width, full.height)) / 2048).rounded())))
        let sw = scan.width, sh = scan.height
        guard sw > 64, sh > 64 else { return nil }
        // The long edges' direction: the field's, where its strips lie along
        // them, not where they are the gaps between frames.
        let vertical = field.map { $0.edges == .long ? $0.vertical : !$0.vertical } ?? (sh > sw)
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
        // A stand-in for an edge without clean rebate says little of where
        // that edge is: it is looked for all the way out from it.
        var nearStandIn = false, farStandIn = false
        if let f = field, f.edges == .long {
            // A stand-in for a missing edge runs parallel to the strip found.
            let slope = { (s: RebateField.Strip) in (s.c1 - s.c0) / (s.a1 - s.a0) * Double(h) / Double(w) }
            tilt = atan((slope(f.near) + slope(f.far)) / 2)
            // Where the strips cross the middle, the stand-in for a missing
            // edge's too: the edge is looked for near it.
            nearStrip = f.near.across(0.5) * Double(h)
            farStrip = f.far.across(0.5) * Double(h)
            nearStandIn = f.onlyEdge == f.farName
            farStandIn = f.onlyEdge == f.nearName
        } else if let f = field {
            // The gaps between frames run across the long edges: turned with
            // the frame, they lean the other way.
            let slope = { (s: RebateField.Strip) in (s.c1 - s.c0) / (s.a1 - s.a0) * Double(w) / Double(h) }
            tilt = -atan((slope(f.near) + slope(f.far)) / 2)
        }

        // Roll film: the gaps between frames, along the long edges, where they
        // show: the field's own strips when it was measured on them, else
        // looked for. Each side's own: a stand-in for a gap that did not show
        // is no gap.
        let gaps: (near: Double?, far: Double?) = {
            guard format.isRollFilm, let f = field,
                  let g = f.edges == .short ? f : RebateField.detectGaps(in: full, format: format) else { return (nil, nil) }
            return (g.onlyEdge == g.farName ? nil : g.near.across(0.5) * Double(w),
                    g.onlyEdge == g.nearName ? nil : g.far.across(0.5) * Double(w))
        }()

        var top = 0.0, bottom = Double(h - 1), left = 0.0, right = Double(w - 1)
        var longFound = 0, endsFound = 0
        var level = Level(density, width: w, height: h, tilt: tilt)
        var edgeSlopes: [Double] = []
        var nearHolder = false, farHolder = false
        for pass in 0..<3 {
            // The long edges, over the middle 70% of the length.
            let along = Int(0.15 * Double(w))..<Int(0.85 * Double(w))
            // From a little outside the strip, in case the rebate finder took a
            // flat band of the picture next to the rebate for it.
            let nearLo = nearStandIn ? 0 : nearStrip.map { Int($0 - 0.05 * Double(h)) } ?? 0
            let nearHi = nearStrip.map { Int($0 + 0.08 * Double(h)) } ?? Int(0.35 * Double(h))
            let farLo = farStrip.map { Int($0 - 0.08 * Double(h)) } ?? Int(0.65 * Double(h))
            let farHi = farStandIn ? h : farStrip.map { Int($0 + 0.05 * Double(h)) + 1 } ?? h
            var t = level.edgeAcross(columns: along, in: nearLo..<nearHi, inward: 1)
            var b = level.edgeAcross(columns: along, in: farLo..<farHi, inward: -1)
            // Roll film with no clean base outside an edge: a carrier over the
            // film's edge. Its edge is not the film's, so it does not level the
            // frame. (A 35 mm carrier shows the rebate, sprocket holes and all.)
            nearHolder = false; farHolder = false
            if format.isRollFilm, t == nil, let e = level.holderEdge(columns: along, inward: 1) { t = e; nearHolder = true }
            if format.isRollFilm, b == nil, let e = level.holderEdge(columns: along, inward: -1) { b = e; farHolder = true }
            top = t ?? nearStrip.map { $0 + (field?.near.half ?? 0) * Double(h) } ?? 0
            bottom = b ?? farStrip.map { $0 - (field?.far.half ?? 0) * Double(h) } ?? Double(h - 1)
            longFound = (t == nil ? 0 : 1) + (b == nil ? 0 : 1)

            // The frame ends, over the middle 80% of the picture's height.
            let inset = 0.1 * (bottom - top)
            let rows = Int(top + inset)..<max(Int(bottom - inset), Int(top + inset) + 1)
            // Roll film: from a gap inwards, where one shows on that side with
            // room for a frame beyond it; where the picture is too thin at the
            // gap for a step, the end is where the gap's bare base stops, going
            // in. The other end, with no gap of its own, a frame's length on,
            // give or take 12%, else just that. 35 mm, and roll film with no
            // gap showing: in the outer 35% at either end.
            let length = format.aspect * (bottom - top)
            var nearGap = gaps.near, farGap = gaps.far
            if let n = nearGap, let f = farGap, f - n < 0.88 * length { nearGap = nil; farGap = nil }
            // More than a frame between them (two 6 x 4.5 frames fit a scan):
            // the gap nearer the scan's middle, and a frame's length in from it.
            if let n = nearGap, let f = farGap, f - n > 1.5 * length {
                if abs(n - Double(w) / 2) <= abs(f - Double(w) / 2) { farGap = nil } else { nearGap = nil }
            }
            if let n = nearGap, Double(w) - n < 0.88 * length { nearGap = nil }
            if let f = farGap, f < 0.88 * length { farGap = nil }
            let reach = Int(0.08 * Double(w)), back = Int(0.03 * Double(w))
            var l: Double?, r: Double?
            if let n = nearGap {
                l = level.edgeAlong(rows: rows, in: max(Int(n) - back, 0)..<min(Int(n) + reach, w), inward: 1)
                left = l ?? level.baseEnd(rows: rows, from: Int(n), inward: 1)
            }
            if let f = farGap {
                r = level.edgeAlong(rows: rows, in: max(Int(f) - reach, 0)..<min(Int(f) + back + 1, w), inward: -1)
                right = r ?? level.baseEnd(rows: rows, from: Int(f), inward: -1)
            }
            // A frame's length on from the end found, give or take 12%.
            func farEnd(from left: Double) -> (Double?, Double) {
                let window = Int(left + 0.88 * length)..<Int(left + 1.12 * length) + 1
                let r = level.edgeAlong(rows: rows, in: max(window.lowerBound, 0)..<min(window.upperBound, w), inward: -1)
                return (r, r ?? min(left + length, Double(w - 1)))
            }
            func nearEnd(from right: Double) -> (Double?, Double) {
                let window = Int(right - 1.12 * length)..<Int(right - 0.88 * length) + 1
                let l = level.edgeAlong(rows: rows, in: max(window.lowerBound, 0)..<min(window.upperBound, w), inward: 1)
                return (l, l ?? max(right - length, 0))
            }
            switch (nearGap, farGap) {
            case (nil, nil):
                l = level.edgeAlong(rows: rows, in: 0..<Int(0.35 * Double(w)), inward: 1)
                r = level.edgeAlong(rows: rows, in: Int(0.65 * Double(w))..<w, inward: -1)
                if format.isRollFilm, let le = l, r == nil {
                    (r, right) = farEnd(from: le); left = le
                } else if format.isRollFilm, let re = r, l == nil {
                    (l, left) = nearEnd(from: re); right = re
                } else {
                    left = l ?? level.gapEnd(rows: rows, from: Int(0.35 * Double(w)), outward: -1)
                    right = r ?? level.gapEnd(rows: rows, from: Int(0.65 * Double(w)), outward: 1)
                }
            case (_?, nil):
                (r, right) = farEnd(from: left)
            case (nil, _?):
                (l, left) = nearEnd(from: right)
            default:
                break
            }
            endsFound = (l == nil ? 0 : 1) + (r == nil ? 0 : 1)

            // The strips' tilt, refined from the long edges themselves: where
            // each lies in eight stretches of the picture, through the median
            // of the slopes between every two stretches, so a stretch that
            // caught the soft step a few pixels inside the gate's edge does
            // not lean the line. The steadier edge counts for more.
            guard pass < 2 else { break }
            var fits: [(slope: Double, weight: Double)] = []
            edgeSlopes = []
            // An edge without clean rebate of its own (a stand-in) is the less
            // sure one: the tilt comes from the other.
            for (edge, inward, standIn) in [(t, 1, nearStandIn || nearHolder), (b, -1, farStandIn || farHolder)] {
                guard let e = edge, !standIn else { continue }
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
            if fits.isEmpty {
                // Neither long edge is the film's own (a holder's, or a stand-in):
                // the frame ends are, the gate's edges at the gaps. Where each
                // lies in eight stretches of the picture's height, the same way.
                for (end, inward) in [(l, 1), (r, -1)] {
                    guard let e = end else { continue }
                    let reachEnd = Int(0.03 * Double(w))
                    let window = max(Int(e) - reachEnd, 0)..<min(Int(e) + reachEnd + 1, w)
                    var ys: [Double] = [], xs: [Double] = []
                    for j in 0..<8 {
                        let r0 = top + (bottom - top) * (0.04 + 0.92 * Double(j) / 8)
                        let r1 = top + (bottom - top) * (0.04 + 0.92 * Double(j + 1) / 8)
                        if let x = level.edgeAlong(rows: Int(r0)..<Int(r1), in: window, inward: inward) {
                            ys.append((r0 + r1) / 2); xs.append(x)
                        }
                    }
                    guard ys.count >= 5 else { continue }
                    var pairs: [Float] = []
                    for i in ys.indices { for j in ys.indices where j > i { pairs.append(Float((xs[j] - xs[i]) / (ys[j] - ys[i]))) } }
                    let lean = Double(Stats.median(pairs))
                    let centre = Stats.median(zip(ys, xs).map { Float($0.1 - lean * $0.0) })
                    let spread = Stats.median(zip(ys, xs).map { abs(Float($0.1 - lean * $0.0) - centre) })
                    // An end leaning dx/dy is the frame turned by -atan(dx/dy).
                    fits.append((-lean, 1 / (Double(spread * spread) + 0.25)))
                    edgeSlopes.append(-atan(lean) * 180 / .pi)
                }
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
        /// `inward` (+1 down, -1 up), out of flat base. Failing that, out of
        /// rebate that light spread from a dense picture across the gate's
        /// edge has fogged: a clear step, and a straight one, the same in at
        /// least three of the four quarters of the columns.
        func edgeAcross(columns: Range<Int>, in window: Range<Int>, inward: Int) -> Double? {
            let cols = Array(max(columns.lowerBound, 0)..<min(columns.upperBound, w))
            func find(_ cs: ArraySlice<Int>, _ window: Range<Int>, fogged: Bool) -> Double? {
                let cs = Array(cs)
                return PictureFinder.edge(lines: cs.count, positions: h, in: window, inward: inward, outside: 8,
                                          fogged: fogged) { l, p in pixels[p * w + cs[l]] }
            }
            if let e = find(cols[...], window, fogged: false) { return e }
            guard let e = find(cols[...], window, fogged: true) else { return nil }
            let q = cols.count / 4
            guard q >= 8 else { return nil }
            let near = Int(e) - 6..<Int(e) + 7
            let agree = (0..<4).filter { i in
                find(cols[(i * q)..<((i + 1) * q)], near, fogged: true).map { abs($0 - e) <= 3 } ?? false
            }.count
            return agree >= 3 ? e : nil
        }

        /// A long edge where a holder covers the film's edge: in from the scan's
        /// border (`inward` +1 from the top, -1 from the bottom), the median
        /// over each quarter of `columns` at least 1.5 D over the base (the
        /// holder's opaque band, at least four rows of it), then a fall, soft
        /// where the holder is out of focus, to where it levels off within 30
        /// rows, a decade or more under the holder. At least three quarters
        /// show it, on a line to within 3 rows (the holder need not lie square
        /// to the film), and the innermost is taken, so the crop keeps clear of
        /// the holder. Inside it either the picture (over
        /// 0.2 D) or a sliver of rebate at the base's level, at most 4% of the
        /// height wide, and the picture's edge is where that steps up; wider
        /// bare base is rebate, the strips' business, and nil.
        func holderEdge(columns: Range<Int>, inward: Int) -> Double? {
            let cols = Array(max(columns.lowerBound, 0)..<min(columns.upperBound, w))
            guard cols.count >= 32 else { return nil }
            // The median across the columns, on the rows asked for only (NaN on
            // the others): each is a sort, and the whole frame's would cost
            // more than everything else Crop to Picture does.
            func profile(_ cs: ArraySlice<Int>, rows: Range<Int>) -> [Float] {
                var m = [Float](repeating: .nan, count: h)
                let lo = max(rows.lowerBound, 0), hi = min(rows.upperBound, h)
                guard lo < hi else { return m }
                for r in lo..<hi {
                    let v = cs.compactMap { c -> Float? in let d = pixels[r * w + c]; return d.isNaN ? nil : d }
                    if !v.isEmpty { m[r] = Stats.median(v) }
                }
                return m
            }
            // The row where the holder's fall levels off, on one median profile.
            func fall(_ m: [Float]) -> Double? {
                let rows = inward > 0 ? Array(0..<(h / 2)) : Array(stride(from: h - 1, through: h / 2, by: -1))
                var i = 0
                while i < rows.count, m[rows[i]].isNaN { i += 1 }          // turned-in corners
                let first = i
                while i < rows.count, !m[rows[i]].isNaN, m[rows[i]] >= 1.5 { i += 1 }
                guard i - first >= 4, i < rows.count else { return nil }
                let plateau = Stats.median(Array(rows[first..<min(first + 8, i)]).map { m[$0] })
                // Into the fall, then on until it stops falling.
                var j = first
                while j < rows.count, !m[rows[j]].isNaN, m[rows[j]] > plateau - 1 { j += 1 }
                guard j + 2 < rows.count, j - (i - 1) <= 30 else { return nil }
                var s = j
                while s + 2 < rows.count, s - j < 30,
                      m[rows[s]] - m[rows[s + 1]] >= 0.03 || m[rows[s + 1]] - m[rows[s + 2]] >= 0.03 { s += 1 }
                guard s - j < 30, !m[rows[s]].isNaN, plateau - m[rows[s]] >= 1 else { return nil }
                return Double(rows[s])
            }
            let q = cols.count / 4
            let half = inward > 0 ? 0..<(h / 2) : (h / 2)..<h        // the rows fall() reads
            let found = (0..<4).compactMap { i -> (x: Double, e: Double)? in
                fall(profile(cols[(i * q)..<((i + 1) * q)], rows: half)).map { (Double(i) + 0.5, $0) }
            }
            guard found.count >= 3 else { return nil }
            // On a line to within 3 rows, all of them or three with one left out.
            func straight(_ pts: [(x: Double, e: Double)]) -> Bool {
                let mx = pts.map(\.x).reduce(0, +) / Double(pts.count), my = pts.map(\.e).reduce(0, +) / Double(pts.count)
                let sxx = pts.map { ($0.x - mx) * ($0.x - mx) }.reduce(0, +)
                let slope = sxx > 0 ? pts.map { ($0.x - mx) * ($0.e - my) }.reduce(0, +) / sxx : 0
                return pts.allSatisfy { abs($0.e - (my + slope * ($0.x - mx))) <= 3 }
            }
            let sets = [found] + (found.count == 4 ? found.indices.map { i in found.enumerated().filter { $0.offset != i }.map(\.element) } : [])
            guard let kept = sets.first(where: straight) else { return nil }
            let e = inward > 0 ? kept.map(\.e).max()! : kept.map(\.e).min()!
            // What lies inside: the picture, or a sliver of rebate and then the picture.
            let first = Int(e) + 2 * inward
            let span = Int(0.04 * Double(h))
            let m = profile(cols[...], rows: inward > 0 ? first..<(first + span + 1) : (first - span)..<(first + 1))
            var k = 0, base = 0
            while k <= span {
                let r = first + inward * k
                guard r >= 0, r < h else { return nil }
                let v = m[r]
                if !v.isNaN {
                    if v > 0.2 { break }
                    if v >= -0.15 { base += 1 }
                }
                k += 1
            }
            guard k <= span else { return nil }          // bare base all the way: rebate, not a holder's edge
            if base == 0 { return e }
            // A sliver of rebate: the picture's edge is its step up.
            let window = inward > 0 ? Int(e)..<(first + k + 4) : (first - k - 4)..<(Int(e) + 1)
            return PictureFinder.edge(lines: cols.count, positions: h, in: window, inward: inward, outside: 2) { l, p in
                pixels[p * w + cols[l]]
            } ?? Double(first + inward * k)
        }

        /// A frame end where no step into the picture shows (the picture as
        /// thin as the base at the gap): from inside the gap, at `from`, in
        /// across its bare base (`inward` +1 right, -1 left), to the first of
        /// three columns in a row that are not: over 0.15 D from the base, or
        /// not flat (a median change from each row to the fourth one on of
        /// 0.0075 D or more).
        func baseEnd(rows: Range<Int>, from start: Int, inward: Int) -> Double {
            let rs = Array(max(rows.lowerBound, 0)..<min(rows.upperBound, h))
            var x = min(max(start, 0), w - 1), run = 0
            while x >= 0 && x < w {
                let v = rs.compactMap { r -> Float? in let d = pixels[r * w + x]; return d.isNaN ? nil : d }
                let changes = (0..<max(rs.count - 4, 0)).compactMap { i -> Float? in
                    let a = pixels[rs[i] * w + x], b = pixels[rs[i + 4] * w + x]
                    return a.isNaN || b.isNaN ? nil : abs(b - a)
                }
                let bare = !v.isEmpty && abs(Stats.median(v)) < 0.15 && !changes.isEmpty && Stats.median(changes) < 0.0075
                if bare { run = 0 } else {
                    run += 1
                    if run >= 3 { return Double(x - inward * (run - 1)) }
                }
                x += inward
            }
            return Double(x - inward)
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
    /// position. `fogged`: out of rebate fogged next to a dense picture, up to
    /// 0.6 D over the base and sloping (a median change of 0.05 D), by a step
    /// of 0.15 D at least.
    fileprivate static func edge(lines n: Int, positions m: Int, in window: Range<Int>, inward: Int, outside ow: Int,
                                 fogged: Bool = false, value: (Int, Int) -> Float) -> Double? {
        let (maxOut, maxFlat, minStep): (Float, Float, Float) = fogged ? (0.6, 0.05, 0.15) : (0.2, 0.015, 0.02)
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
            guard let out = median(outs.map { level[$0 - lo] }), out <= maxOut, out >= -0.15,
                  let flat = median(outs.map { flatness[$0 - lo] }), flat <= maxFlat, flat < (best?.flat ?? .infinity),
                  let step = median((0..<n).map { (value($0, p + k) - value($0, p - k)) * Float(inward) }),
                  step >= minStep else { continue }
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
