import Foundation
import ImageIO

/// What a roll was shot with and when, for the exported files: the camera
/// that took the pictures on film, not the one that scanned them. Kept apart
/// from the print settings, so typing here never reprints the frame.
struct CaptureInfo: Codable, Equatable {
    /// "Leica M6": the first word is written as the make, the whole as the model.
    var camera = ""
    var lens = ""
    /// The day it was shot; nil leaves the scan's date as the picture's.
    var date: Date?
    /// The speed the film was exposed at; nil is its box speed, doubled for
    /// each stop of push the stock names.
    var exposureIndex: Int?
    /// Developer, lab, anything else, written into the description.
    var notes = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        camera = try c.decodeIfPresent(String.self, forKey: .camera) ?? ""
        lens = try c.decodeIfPresent(String.self, forKey: .lens) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date)
        exposureIndex = try c.decodeIfPresent(Int.self, forKey: .exposureIndex)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    /// The roll's, with what a frame has of its own.
    func applying(_ frame: FrameCapture?) -> CaptureInfo {
        var c = self
        if let lens = frame?.lens, !lens.isEmpty { c.lens = lens }
        if let date = frame?.date { c.date = date }
        return c
    }
}

/// A frame's own lens and date, where they are not the roll's.
struct FrameCapture: Codable, Equatable {
    var lens: String?
    var date: Date?

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lens = try c.decodeIfPresent(String.self, forKey: .lens)
        date = try c.decodeIfPresent(Date.self, forKey: .date)
    }
}

/// The exported file's metadata: the scan's (`PrintExporter.exportProperties`
/// writes what describes the photograph), with the print's film and paper
/// always written, and the camera, lens, date and speed it was shot with
/// where they are given.
///
/// The film and the paper go into the description (TIFF ImageDescription,
/// EXIF UserComment, IPTC caption), which photo libraries show as the
/// caption: EXIF has no tag for a film. A camera or lens given replaces the
/// scanning camera's, and the scan's exposure (its shutter, aperture, focal
/// length, ISO) is left out, as it is not the picture's; the film's speed is
/// the ISO. A date given becomes the picture's, and the scan's date becomes
/// the date it was digitized.
enum ExportMetadata {
    struct Print {
        var film: String
        var paper: String
        /// The film's speed as shot.
        var speed: Int?
    }

    /// The stocks whose names carry no speed, at the speed their sheets rate
    /// them to daylight (Ortho Plus is ISO 40 to tungsten).
    static let unnamedSpeeds: [String: Int] = [
        "ilford_hp5_plus": 400, "ilford_fp4_plus": 125, "ilford_pan_f_plus": 50, "ilford_ortho_plus": 80,
    ]

    /// The speed a stock is rated at, from its name ("Portra 800 (Push 1)"
    /// is 800 pushed one stop: EI 1600).
    static func speed(stock: String) -> Int? {
        let name = (try? PackLibrary.shared.pack(stock))?.name ?? stock
        let rated: Int?
        // The last number of a word that is one ("400", "C200", "500T"), not
        // a model ("Vision3", "HP5"), before any "(Push n)".
        func numbers(_ text: Substring) -> [Int] {
            text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap { word in
                let digits = word.split(whereSeparator: { !$0.isNumber }).last
                return digits.flatMap { Int($0) }
            }
        }
        if let speed = unnamedSpeeds[stock] {
            rated = speed
        } else {
            let base = name.split(separator: "(").first ?? Substring(name)
            rated = numbers(base).filter { $0 >= 6 }.last
        }
        guard let rated else { return nil }
        var push = 0
        if let r = name.range(of: "Push ") { push = Int(String(name[r.upperBound...].prefix(1))) ?? 0 }
        return rated << push
    }

    /// The caption written into the file.
    static func description(print: Print, capture: CaptureInfo, source: [CFString: Any]?) -> String {
        var parts: [String] = []
        var film = print.film
        if let ei = capture.exposureIndex ?? print.speed, ei != print.speed || capture.exposureIndex != nil {
            film += " at EI \(ei)"
        }
        parts.append("\(film), printed on \(print.paper).")
        let camera = capture.camera.trimmingCharacters(in: .whitespaces)
        let lens = capture.lens.trimmingCharacters(in: .whitespaces)
        // In English, as the rest of the caption is: "2 April 2026".
        let day = capture.date.map { $0.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(Locale(identifier: "en_GB"))) }
        if !camera.isEmpty || !lens.isEmpty {
            parts.append("Shot with " + [camera, lens].filter { !$0.isEmpty }.joined(separator: " and ")
                         + (day.map { " on \($0)" } ?? "") + ".")
        } else if let day {
            parts.append("Shot on \(day).")
        }
        let notes = capture.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append(notes.hasSuffix(".") ? notes : notes + ".") }
        let scanner = scanEquipment(source)
        parts.append(scanner.isEmpty ? "Printed in FLX Film Convert." : "Scanned with \(scanner), printed in FLX Film Convert.")
        return parts.joined(separator: " ")
    }

    /// The scanning camera and lens, as the scan names them.
    static func scanEquipment(_ source: [CFString: Any]?) -> String {
        let tiff = source?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = source?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let aux = source?[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        let lens = ((exif?[kCGImagePropertyExifLensModel] as? String) ?? (aux?[kCGImagePropertyExifAuxLensModel] as? String))?
            .trimmingCharacters(in: .whitespaces)
        return [model, lens].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The tags the scan's exposure set, which a print from film does not have.
    private static let scanExposure: [CFString] = [
        kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber, kCGImagePropertyExifExposureProgram,
        kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifSensitivityType,
        kCGImagePropertyExifRecommendedExposureIndex, kCGImagePropertyExifStandardOutputSensitivity,
        kCGImagePropertyExifShutterSpeedValue, kCGImagePropertyExifApertureValue,
        kCGImagePropertyExifBrightnessValue, kCGImagePropertyExifExposureBiasValue,
        kCGImagePropertyExifMaxApertureValue, kCGImagePropertyExifSubjectDistance,
        kCGImagePropertyExifMeteringMode, kCGImagePropertyExifLightSource, kCGImagePropertyExifFlash,
        kCGImagePropertyExifFocalLength, kCGImagePropertyExifFocalLenIn35mmFilm,
        kCGImagePropertyExifExposureMode, kCGImagePropertyExifWhiteBalance,
        kCGImagePropertyExifDigitalZoomRatio, kCGImagePropertyExifSceneCaptureType,
        kCGImagePropertyExifGainControl, kCGImagePropertyExifContrast, kCGImagePropertyExifSaturation,
        kCGImagePropertyExifSharpness, kCGImagePropertyExifSubjectDistRange,
        kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifCameraOwnerName,
        kCGImagePropertyExifSensingMethod,
        kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel,
        kCGImagePropertyExifLensSpecification, kCGImagePropertyExifLensSerialNumber,
    ]

    /// EXIF's date form, in the Mac's time zone.
    static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    /// The scan's properties as the exported file should have them.
    static func properties(source: [CFString: Any]?, print: Print, capture: CaptureInfo) -> [CFString: Any] {
        var out = source ?? [:]
        var tiff = source?[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var exif = source?[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var iptc = source?[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        let camera = capture.camera.trimmingCharacters(in: .whitespaces)
        let lens = capture.lens.trimmingCharacters(in: .whitespaces)
        if !camera.isEmpty || !lens.isEmpty {
            // The picture's camera, not the scan's: the scanner's make,
            // model, lens and exposure all go.
            tiff[kCGImagePropertyTIFFMake] = nil
            tiff[kCGImagePropertyTIFFModel] = nil
            for key in scanExposure { exif[key] = nil }
            out[kCGImagePropertyExifAuxDictionary] = nil
            out[kCGImagePropertyMakerNikonDictionary] = nil
            if !camera.isEmpty {
                tiff[kCGImagePropertyTIFFMake] = camera.split(separator: " ").first.map(String.init) ?? camera
                tiff[kCGImagePropertyTIFFModel] = camera
            }
            if !lens.isEmpty { exif[kCGImagePropertyExifLensModel] = lens }
            if let ei = capture.exposureIndex ?? print.speed { exif[kCGImagePropertyExifISOSpeedRatings] = [ei] }
        }
        if let date = capture.date {
            // Noon on the day: a day is what a roll is usually known by.
            let day = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
            if let scanned = exif[kCGImagePropertyExifDateTimeOriginal] {
                exif[kCGImagePropertyExifDateTimeDigitized] = scanned
                exif[kCGImagePropertyExifSubsecTimeDigitized] = exif[kCGImagePropertyExifSubsecTimeOriginal]
                exif[kCGImagePropertyExifOffsetTimeDigitized] = exif[kCGImagePropertyExifOffsetTimeOriginal]
            }
            exif[kCGImagePropertyExifDateTimeOriginal] = exifDate.string(from: day)
            exif[kCGImagePropertyExifSubsecTimeOriginal] = nil
            exif[kCGImagePropertyExifOffsetTimeOriginal] = nil
            iptc[kCGImagePropertyIPTCDateCreated] = String(exifDate.string(from: day).prefix(10)).replacingOccurrences(of: ":", with: "")
            iptc[kCGImagePropertyIPTCTimeCreated] = nil
        }
        let caption = description(print: print, capture: capture, source: source)
        tiff[kCGImagePropertyTIFFImageDescription] = caption
        exif[kCGImagePropertyExifUserComment] = caption
        iptc[kCGImagePropertyIPTCCaptionAbstract] = caption

        out[kCGImagePropertyTIFFDictionary] = tiff
        out[kCGImagePropertyExifDictionary] = exif
        out[kCGImagePropertyIPTCDictionary] = iptc
        return out
    }
}
