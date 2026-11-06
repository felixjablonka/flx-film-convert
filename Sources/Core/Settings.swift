import Foundation
import CoreGraphics

// What the user sets. The roll carries what a darkroom printer sets once for
// a roll, because it belongs to the film and its processing: the stock, the
// paper, the filter pack and any crossover between the layers. Each frame
// carries its print: exposure and contrast, tone, regional colour, dodging
// and burning, effects, and how it is turned, levelled and cut.
//
// Every key decodes as optional, so settings saved by an earlier build keep
// loading when a new one adds a field.

struct RollSettings: Codable, Equatable {
    var filmStock = "kodak_portra_400"
    /// nil: the paper the film's pack names.
    var printStock: String?
    /// The enlarger's yellow and magenta dichroics on top of the stock's own
    /// neutral pack, in CC. More yellow prints bluer, more magenta greener.
    var filterY: Double = 0
    var filterM: Double = 0
    /// Each dye layer's own print curve, for a film or a process whose layers
    /// do not track one another (crossover), which no filter can fix.
    var gradeTrim = RGBTrim.zero
    var toeTrim = RGBTrim.zero
    var shoulderTrim = RGBTrim.zero
    var snapTrim = RGBTrim.zero
    var lightCCT: Double = 5000
    /// A frame of the bare scanning light (a raw file), shot with the roll's
    /// setup, chosen by the user; nil takes the light's falloff from the rebate.
    var flatField: String?
    /// The flat field switched on; off keeps the chosen frame for later.
    var useFlatField = true

    /// The roll as one frame prints it: with the frame's own film and filter
    /// pack, where it has them.
    func applying(_ frame: FrameSettings) -> RollSettings {
        var r = self
        if let f = frame.filmStock { r.filmStock = f }
        if let f = frame.filtration { r.filterY = f.yellow; r.filterM = f.magenta }
        return r
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RollSettings()
        filmStock = try c.decodeIfPresent(String.self, forKey: .filmStock) ?? d.filmStock
        printStock = try c.decodeIfPresent(String.self, forKey: .printStock)
        filterY = try c.decodeIfPresent(Double.self, forKey: .filterY) ?? d.filterY
        filterM = try c.decodeIfPresent(Double.self, forKey: .filterM) ?? d.filterM
        gradeTrim = try c.decodeIfPresent(RGBTrim.self, forKey: .gradeTrim) ?? d.gradeTrim
        toeTrim = try c.decodeIfPresent(RGBTrim.self, forKey: .toeTrim) ?? d.toeTrim
        shoulderTrim = try c.decodeIfPresent(RGBTrim.self, forKey: .shoulderTrim) ?? d.shoulderTrim
        snapTrim = try c.decodeIfPresent(RGBTrim.self, forKey: .snapTrim) ?? d.snapTrim
        lightCCT = try c.decodeIfPresent(Double.self, forKey: .lightCCT) ?? d.lightCCT
        flatField = try c.decodeIfPresent(String.self, forKey: .flatField)
        useFlatField = try c.decodeIfPresent(Bool.self, forKey: .useFlatField) ?? d.useFlatField
    }
}

/// The enlarger's yellow and magenta dichroics on top of the stock's own
/// neutral pack, in CC. More yellow prints bluer, more magenta greener.
struct Filtration: Codable, Equatable {
    var yellow: Double = 0
    var magenta: Double = 0
}

struct FrameSettings: Codable, Equatable {
    /// A film for this frame alone, where a folder mixes rolls; nil is the roll's.
    var filmStock: String?
    /// A filter pack for this frame alone; nil prints with the roll's.
    var filtration: Filtration?
    /// Print exposure in stops; positive is a shorter print time, a lighter print.
    var exposure: Double = 0
    /// FLX Film Lab's print controls, in its own units.
    var brightness: Double = 0
    /// ISO-R paper grade; nil is the stock's own.
    var grade: Double?
    var shadowGrade: Double = 0
    var highlightGrade: Double = 0
    var shadows: Double = 0
    var highlights: Double = 0
    var toe: Double = 0
    var toeWidth: Double = 1
    var shoulder: Double = 0
    var shoulderWidth: Double = 1
    var snap: Double = 0
    var shadowCMY = CMYOffset.zero
    var highlightCMY = CMYOffset.zero
    /// Pre-flash, in the engine's own units (0...0.3), which holds highlights.
    var preflash: Double = 0
    var effects: GlowLook?
    /// A rebate rectangle picked by hand, in frame fractions; nil uses the
    /// rebate along both long edges.
    var rebatePick: CGRect?
    var geometry = FrameGeometry()
    var masks: [LocalMask] = []
    /// The print's detail (`DetailSettings`): unsharp mask on its lightness,
    /// with its radius in pixels of the full-size scan and an edge mask, and
    /// CLAHE local contrast.
    var sharpness: Double = 0
    var sharpenRadius: Double = 1
    var sharpenMasking: Double = 0
    var localContrast: Double = 0

    var detail: DetailSettings {
        DetailSettings(sharpness: sharpness, radius: sharpenRadius, masking: sharpenMasking, localContrast: localContrast)
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FrameSettings()
        filmStock = try c.decodeIfPresent(String.self, forKey: .filmStock)
        filtration = try c.decodeIfPresent(Filtration.self, forKey: .filtration)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? d.exposure
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
        grade = try c.decodeIfPresent(Double.self, forKey: .grade)
        shadowGrade = try c.decodeIfPresent(Double.self, forKey: .shadowGrade) ?? d.shadowGrade
        highlightGrade = try c.decodeIfPresent(Double.self, forKey: .highlightGrade) ?? d.highlightGrade
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? d.shadows
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? d.highlights
        toe = try c.decodeIfPresent(Double.self, forKey: .toe) ?? d.toe
        toeWidth = try c.decodeIfPresent(Double.self, forKey: .toeWidth) ?? d.toeWidth
        shoulder = try c.decodeIfPresent(Double.self, forKey: .shoulder) ?? d.shoulder
        shoulderWidth = try c.decodeIfPresent(Double.self, forKey: .shoulderWidth) ?? d.shoulderWidth
        snap = try c.decodeIfPresent(Double.self, forKey: .snap) ?? d.snap
        shadowCMY = try c.decodeIfPresent(CMYOffset.self, forKey: .shadowCMY) ?? d.shadowCMY
        highlightCMY = try c.decodeIfPresent(CMYOffset.self, forKey: .highlightCMY) ?? d.highlightCMY
        preflash = try c.decodeIfPresent(Double.self, forKey: .preflash) ?? d.preflash
        effects = try c.decodeIfPresent(GlowLook.self, forKey: .effects)
        rebatePick = try c.decodeIfPresent(CGRect.self, forKey: .rebatePick)
        geometry = try c.decodeIfPresent(FrameGeometry.self, forKey: .geometry) ?? d.geometry
        masks = try c.decodeIfPresent([LocalMask].self, forKey: .masks) ?? d.masks
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? d.sharpness
        sharpenRadius = try c.decodeIfPresent(Double.self, forKey: .sharpenRadius) ?? d.sharpenRadius
        sharpenMasking = try c.decodeIfPresent(Double.self, forKey: .sharpenMasking) ?? d.sharpenMasking
        localContrast = try c.decodeIfPresent(Double.self, forKey: .localContrast) ?? d.localContrast
    }
}

extension Recipe {
    /// FLX Film Lab's recipe for printing a scanned negative: its print
    /// controls from the settings, and everything that happens to film in the
    /// camera off, because the scan has the real film's grain, couplers and
    /// halation already.
    static func forPrint(roll: RollSettings, frame: FrameSettings, outputColorSpace: String = "sRGB") -> Recipe {
        var r = Recipe().loadingFilm(roll.filmStock)
        if let paper = roll.printStock {
            r.printStock = paper
        } else if let target = (try? PackLibrary.shared.pack(roll.filmStock))?.targetPrint {
            r.printStock = target
        }
        r.autoExposure = false
        r.exposureEV = 0
        r.autoDensity = false
        r.autoGrade = false
        r.grainEnabled = false
        r.couplersEnabled = false
        r.halationEnabled = false
        r.density = -frame.exposure
        r.brightness = frame.brightness
        if let g = frame.grade { r.grade = g }
        r.shadowGrade = frame.shadowGrade
        r.highlightGrade = frame.highlightGrade
        r.shadows = frame.shadows
        r.highlights = frame.highlights
        r.toe = frame.toe
        r.toeWidth = frame.toeWidth
        r.shoulder = frame.shoulder
        r.shoulderWidth = frame.shoulderWidth
        r.snap = frame.snap
        r.shadowCMY = frame.shadowCMY
        r.highlightCMY = frame.highlightCMY
        r.preflashExposure = frame.preflash
        r.filterShiftY = roll.filterY
        r.filterShiftM = roll.filterM
        r.gradeTrim = roll.gradeTrim
        r.toeTrim = roll.toeTrim
        r.shoulderTrim = roll.shoulderTrim
        r.snapTrim = roll.snapTrim
        r.effects = frame.effects
        r.masks = frame.masks
        r.frameGeometry = frame.geometry
        r.outputColorSpace = outputColorSpace
        return r
    }
}

/// An enlarger meter, used only when asked: the print exposure that puts the
/// median green-record density of what the crop keeps at the stock's
/// mid-grey. A brightness, never a colour.
enum PrintMeter {
    static func exposure(negative cmy: [Float], width: Int, height: Int, geometry: FrameGeometry,
                         film: ProfilePack) -> Double {
        let kept = geometry.metered(cmy, width: width, height: height)
        let n = kept.width * kept.height
        let step = max(1, n / 60_000)
        let m = stride(from: 0, to: n, by: step).map { kept.pixels[$0 * 4 + 1] }
        let curves = film.normalizedDensityCurves
        let pos = (0 - film.logExposureStart) / film.logExposureStep
        let i0 = max(0, min(Int(pos), Constants.curveSamples - 2)), t = pos - Float(i0)
        let mid = curves[i0 * 3 + 1] * (1 - t) + curves[(i0 + 1) * 3 + 1] * t
        // A denser negative needs more print exposure: a negative exposure value.
        return -Double(Stats.median(m) - mid) / log10(2)
    }
}
