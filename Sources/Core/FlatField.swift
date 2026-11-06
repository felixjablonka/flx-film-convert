import Foundation
import ImageIO
import simd

/// A frame of the bare scanning light — no film, the same camera, lens,
/// aperture, holder and light as the roll — as a smooth field: how bright the
/// light is at each point of the frame, relative to its own median.
///
/// Dividing a scan by it takes out the light's falloff exactly, wherever the
/// rebate is or is not, before the rebate is measured. Without one, the falloff
/// comes from the rebate along the long edges (`RebateField`), which matched a
/// measured light to about 0.01 D rms on a Nikon Z f with an Easy35 holder, and missed its
/// off-centre peak by up to 0.03 D.
struct FlatField {
    let url: URL
    /// The camera and lens it was shot with, which a scan must share to use it.
    let camera: Camera?
    let width: Int
    let height: Int
    private let values: [SIMD3<Float>]

    enum Failure: Error, CustomStringConvertible {
        case dark(String), shape(String)
        var description: String {
            switch self {
            case .dark(let name): return "\(name) is too dark to be a frame of the light"
            case .shape(let name): return "\(name) does not have the scan's shape: a light frame from another camera or crop?"
            }
        }
    }

    /// Decodes the light frame, box-filters it to about 256 pixels across and
    /// smooths it, so dust on the diffuser and noise do not print. Where the
    /// holder hides the light the field is held at a floor, so the division
    /// never blows up there.
    static func load(_ url: URL) throws -> FlatField {
        let scan = try Scan.load(url, maxDimension: 1024)
        let small = scan.reduced(by: max(1, scan.width / 256))
        let w = small.width, h = small.height
        var v = (0..<(w * h)).map { i in SIMD3(small.pixels[i * 4], small.pixels[i * 4 + 1], small.pixels[i * 4 + 2]) }
        for _ in 0..<3 {                                  // three 3x3 box passes, about a Gaussian
            var out = v
            for y in 0..<h {
                for x in 0..<w {
                    var acc = SIMD3<Float>(repeating: 0)
                    for dy in -1...1 {
                        for dx in -1...1 {
                            acc += v[min(max(y + dy, 0), h - 1) * w + min(max(x + dx, 0), w - 1)]
                        }
                    }
                    out[y * w + x] = acc / 9
                }
            }
            v = out
        }
        let greens = v.map { $0.y }
        let median = Stats.median(greens)
        guard median > 1e-4 else { throw Failure.dark(url.lastPathComponent) }
        // The level inside the holder's window: the median of what is lit.
        let lit = v.filter { $0.y > 0.6 * median }
        let level = SIMD3(Stats.median(lit.map { $0.x }), Stats.median(lit.map { $0.y }), Stats.median(lit.map { $0.z }))
        let values = v.map { simd_max($0 / level, SIMD3(repeating: 0.2)) }
        return FlatField(url: url, camera: camera(of: url), width: w, height: h, values: values)
    }

    /// The camera and lens a raw file names in its metadata.
    struct Camera: Equatable, CustomStringConvertible {
        var model: String
        var lens: String?

        /// The same camera, and the same lens where both files name one (an
        /// adapted manual lens names none). The aperture is left out: a light
        /// frame a stop off the scans' still holds the light's shape.
        func matches(_ other: Camera) -> Bool {
            guard model == other.model else { return false }
            guard let a = lens, let b = other.lens else { return true }
            return a == b
        }
        var description: String { lens.map { "a \(model) with the \($0)" } ?? "a \(model)" }
    }

    static func camera(of url: URL) -> Camera? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let tidy = { (v: Any?) -> String? in
            guard let t = (v as? String)?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            return t
        }
        guard let model = tidy((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel]) else { return nil }
        let lens = tidy((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel])
        return Camera(model: model, lens: lens)
    }

    /// The light at a point given as fractions of the frame, bilinear.
    func value(x: Double, y: Double) -> SIMD3<Float> {
        let fx = min(max(x * Double(width) - 0.5, 0), Double(width - 1))
        let fy = min(max(y * Double(height) - 0.5, 0), Double(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        let top = values[y0 * width + x0] * (1 - tx) + values[y0 * width + x1] * tx
        let bottom = values[y1 * width + x0] * (1 - tx) + values[y1 * width + x1] * tx
        return top * (1 - ty) + bottom * ty
    }

    /// Whether a scan of `width` x `height` has this frame's shape.
    func fits(width sw: Int, height sh: Int) -> Bool {
        abs(Double(sw) / Double(sh) - Double(width) / Double(height)) < 0.02 * Double(width) / Double(height)
    }
}

extension Scan {
    /// The scan as if the light were even: each pixel divided by the light there.
    func flattened(by flat: FlatField) throws -> Scan {
        guard flat.fits(width: width, height: height) else { throw FlatField.Failure.shape(flat.url.lastPathComponent) }
        var out = pixels
        let w = width, h = height
        out.withUnsafeMutableBufferPointer { o in
            let o = o
            DispatchQueue.concurrentPerform(iterations: h) { y in
                let fy = (Double(y) + 0.5) / Double(h)
                for x in 0..<w {
                    let f = flat.value(x: (Double(x) + 0.5) / Double(w), y: fy)
                    let i = (y * w + x) * 4
                    o[i] /= f.x; o[i + 1] /= f.y; o[i + 2] /= f.z
                }
            }
        }
        return Scan(width: w, height: h, pixels: out)
    }
}
