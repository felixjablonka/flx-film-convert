import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// The sidebar's prints, kept on disk by what made them: the scan file as it
/// is on disk and the settings it is printed with. A frame whose scan and
/// settings have not changed shows its print at once, from the last time.
enum ThumbnailCache {
    /// Off for the self-check, whose settings are not saved.
    static var enabled = true

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FLX Film Convert/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// "<frame>/<settings>": the frame's folder in the cache, and in it the
    /// print of what it is set to now, which changes with the scan file and
    /// with anything the print depends on.
    static func key(_ url: URL, roll: RollSettings, frame: FrameSettings) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let settings = [(try? encoder.encode(roll)), (try? encoder.encode(frame))]
            .map { $0.map { String(decoding: $0, as: UTF8.self) } ?? "" }
        func hash(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        }
        return hash(url.path) + "/" + hash("1|\(modified)|\(size)|\(settings[0])|\(settings[1])")
    }

    private static func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".jpg") }

    static func load(_ key: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(file(key) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Keeps one print a frame: the one before it goes, as nothing will ask
    /// for it again unless the settings go back.
    static func save(_ image: CGImage, key: String) {
        guard enabled else { return }
        let url = file(key)
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        if let old = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for f in old where f.lastPathComponent != url.lastPathComponent { try? fm.removeItem(at: f) }
        }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}

/// Makes the sidebar's prints of a roll in the background, one frame after
/// another at utility priority, on a converter of its own, so the frame being
/// worked on prints as fast as before. A new list supersedes the one running.
final class ThumbnailMaker {
    struct Job {
        var url: URL
        var roll: RollSettings
        var frame: FrameSettings
        var key: String
    }

    private let queue = DispatchQueue(label: "lab.flx.FLXFilmConvert.thumbnails", qos: .utility)
    private let lock = NSLock()
    private var generation = 0
    private var converter: Converter?

    /// Each frame's print, from the cache or made, as it is ready.
    func make(_ jobs: [Job], deliver: @escaping (Job, CGImage) -> Void) {
        lock.lock(); generation += 1; let mine = generation; lock.unlock()
        queue.async {
            for job in jobs {
                self.lock.lock(); let current = self.generation == mine; self.lock.unlock()
                guard current else { return }
                if let cached = ThumbnailCache.load(job.key) {
                    if Pipeline.timing { print("thumbnail \(job.url.lastPathComponent) cached") }
                    DispatchQueue.main.async { deliver(job, cached) }
                    continue
                }
                autoreleasepool {
                    do {
                        if self.converter == nil { self.converter = try Converter() }
                        let t0 = CFAbsoluteTimeGetCurrent()
                        let out = try self.converter!.thumbnail(job.url, roll: job.roll, frame: job.frame)
                        if Pipeline.timing {
                            print(String(format: "thumbnail %@ %.0f ms", job.url.lastPathComponent, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
                        }
                        guard let bytes = out.display,
                              let image = Pipeline.image(bytes, width: out.width, height: out.height,
                                                         space: CGColorSpace(name: CGColorSpace.sRGB)!),
                              let thumb = Pipeline.thumbnail(image) else { return }
                        ThumbnailCache.save(thumb, key: job.key)
                        DispatchQueue.main.async { deliver(job, thumb) }
                    } catch {
                        // No rebate found, or an unreadable file: the scan's own preview stays.
                    }
                }
            }
        }
    }

    func cancel() {
        lock.lock(); generation += 1; lock.unlock()
    }
}
