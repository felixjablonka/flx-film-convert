import SwiftUI
import AppKit

@main
struct FLXFilmConvertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = ConvertModel()

    var body: some Scene {
        WindowGroup("FLX Film Convert") {
            ContentView(model: model)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear { if !SelfCheck.start(model) { model.restore() } }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Roll…") { model.chooseFolder() }.keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Export Frame…") { model.exportFrame() }.keyboardShortcut("e")
                Button("Export Roll…") { model.exportRoll() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Frame") {
                Button("Previous Frame") { model.select(offset: -1) }.keyboardShortcut(.upArrow, modifiers: [.command])
                Button("Next Frame") { model.select(offset: 1) }.keyboardShortcut(.downArrow, modifiers: [.command])
                Divider()
                Button("Turn Left") { model.turn(clockwise: false) }.keyboardShortcut("[")
                Button("Turn Right") { model.turn(clockwise: true) }.keyboardShortcut("]")
                Button(model.isCropping ? "Done Cropping" : "Crop") { model.isCropping.toggle() }.keyboardShortcut("r")
                Button("Meter Exposure") { model.meter() }.keyboardShortcut("m")
                Button(model.loupeOn ? "Hide Loupe" : "Show Loupe") { model.loupeOn.toggle() }.keyboardShortcut("l")
                Button("Reset Frame…") { model.resetFrame() }.keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Copy Print Settings") { model.copyPrintSettings() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.selection == nil)
                Button(model.copiedPrint.map { "Paste Print Settings of \($0.source)" } ?? "Paste Print Settings") {
                    model.pastePrintSettings()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(model.copiedPrint == nil || model.selection == nil)
                Divider()
                Button(model.showScan ? "Show the Print" : "Show the Scan") { model.showScan.toggle() }
                    .keyboardShortcut("n")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// A self-check for development: with FLXCONVERT_SNAPSHOT=out.png (and
/// FLXCONVERT_OPEN=folder, FLXCONVERT_SELECT=file name, FLXCONVERT_SCAN=1 for
/// the scan view, and _FILM, _TURNS, _STRAIGHTEN, _EXPOSURE, _GRADE, _CROPPING,
/// _CROP, _MASK, _SIZE, _FRESH for no saved settings, _SHARPNESS, _RADIUS, _MASKING, _CLAHE, _LOUPE=x,y,
/// _ROLL_FILTER=y,m, _FRAME_FILTER=y,m, _FORMAT=66, _CURVES=rgb:0,0 64,40 255,255 (as --curves),
/// _SPACE=Display P3 (the export's colour space), _APPEARANCE=dark or light, _TAB=export, _CAMERA, _LENS, _FRAME_LENS, _DATE=1, _THUMBS=1 for the
/// sidebar's prints, _CACHE=1 to cache them, _WAIT=seconds before the snapshot, _CURVE_TEST=1 to
/// click and drag the curves editor, _PASTE_TEST=1 to copy and paste print settings), the app
/// opens the roll, waits for the print (and the loupe), draws its own
/// window into the PNG and quits. Nothing is captured from the screen.
enum SelfCheck {
    static let env = ProcessInfo.processInfo.environment
    static var active: Bool { env["FLXCONVERT_SNAPSHOT"] != nil }

    /// For screenshots (FLXCONVERT_ACTIVE=1): the window drawn as the active
    /// one. A shell-launched app never becomes active, so its window draws
    /// dimmed; this answers yes to "are you key, main, active" instead.
    private static func lookActive() {
        func swap(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
            guard let a = class_getInstanceMethod(cls, original), let b = class_getInstanceMethod(cls, replacement) else { return }
            method_exchangeImplementations(a, b)
        }
        swap(NSWindow.self, #selector(getter: NSWindow.isKeyWindow), #selector(NSWindow.selfCheckIsKey))
        swap(NSWindow.self, #selector(getter: NSWindow.isMainWindow), #selector(NSWindow.selfCheckIsKey))
        swap(NSApplication.self, #selector(getter: NSApplication.isActive), #selector(NSApplication.selfCheckIsActive))
    }

    @MainActor static func start(_ model: ConvertModel) -> Bool {
        guard active else { return false }
        if env["FLXCONVERT_ACTIVE"] == "1" { lookActive() }
        if let a = env["FLXCONVERT_APPEARANCE"] { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
        model.persists = false
        ThumbnailCache.enabled = env["FLXCONVERT_CACHE"] == "1"
        model.makesThumbnails = env["FLXCONVERT_THUMBS"] == "1"
        // Launched from a shell it runs in the background, where App Nap would
        // throttle its timers and the sweep would measure the throttling.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "FLX Film Convert self-check")
        if let size = env["FLXCONVERT_SIZE"]?.split(separator: ",").compactMap({ Double($0) }), size.count == 2,
           let window = NSApp.windows.first {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        if let folder = env["FLXCONVERT_OPEN"] { model.open(folder: URL(fileURLWithPath: folder)) }
        if let name = env["FLXCONVERT_SELECT"], let f = model.frames.first(where: { $0.url.lastPathComponent == name }) {
            model.selection = f.url
        }
        if env["FLXCONVERT_FRESH"] == "1" { model.frame = FrameSettings() }
        if let film = env["FLXCONVERT_FILM"] { model.frame.filmStock = film }
        if let f = env["FLXCONVERT_FORMAT"].flatMap(FrameFormat.init(argument:)) { model.roll.format = f }
        if let flat = env["FLXCONVERT_FLAT"] { model.useAsFlatField(URL(fileURLWithPath: flat)) }
        if env["FLXCONVERT_SCAN"] == "1" { model.showScan = true }
        if let t = env["FLXCONVERT_TURNS"].flatMap(Int.init) { model.frame.geometry.quarterTurns = t }
        if let d = env["FLXCONVERT_STRAIGHTEN"].flatMap(Double.init) { model.setStraighten(d) }
        if let e = env["FLXCONVERT_EXPOSURE"].flatMap(Double.init) { model.frame.exposure = e }
        if let g = env["FLXCONVERT_GRADE"].flatMap(Double.init) { model.frame.grade = g }
        if env["FLXCONVERT_CROPPING"] == "1" { model.isCropping = true }
        if let p = env["FLXCONVERT_ROLL_FILTER"]?.split(separator: ",").compactMap({ Double($0) }), p.count == 2 {
            model.roll.filterY = p[0]; model.roll.filterM = p[1]
        }
        if let p = env["FLXCONVERT_FRAME_FILTER"]?.split(separator: ",").compactMap({ Double($0) }), p.count == 2 {
            model.setFiltersThisFrame(true)
            model.filterY = p[0]; model.filterM = p[1]
        }
        if let c = env["FLXCONVERT_CAMERA"] { model.capture.camera = c }
        if let c = env["FLXCONVERT_LENS"] { model.capture.lens = c }
        if let c = env["FLXCONVERT_FRAME_LENS"] { model.frameCapture.lens = c }
        if env["FLXCONVERT_DATE"] != nil { model.capture.date = Date(timeIntervalSince1970: 1_778_760_000) }
        if let v = env["FLXCONVERT_SHARPNESS"].flatMap(Double.init) { model.frame.sharpness = v }
        if let v = env["FLXCONVERT_RADIUS"].flatMap(Double.init) { model.frame.sharpenRadius = v }
        if let v = env["FLXCONVERT_MASKING"].flatMap(Double.init) { model.frame.sharpenMasking = v }
        if let v = env["FLXCONVERT_CLAHE"].flatMap(Double.init) { model.frame.localContrast = v }
        if let c = env["FLXCONVERT_CURVES"] { model.frame.curves = PrintCurves(spec: c) }
        if let space = env["FLXCONVERT_SPACE"] { model.outputColorSpace = space }
        if let p = env["FLXCONVERT_LOUPE"]?.split(separator: ",").compactMap({ Double($0) }), p.count == 2 {
            model.loupeCentre = CGPoint(x: p[0], y: p[1])
            model.loupeOn = true
            // Dragged across the print, to time the loupe as it follows.
            if env["FLXCONVERT_LOUPE_DRAG"] == "1" {
                for k in 1...12 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6 + Double(k) * 0.05) {
                        model.moveLoupe(to: CGPoint(x: p[0] + Double(k) * 0.01, y: p[1]))
                    }
                }
            }
        }
        // Masks and the crop need the display map or the field, which arrive with the first render.
        poll(model, tries: 0, crop: env["FLXCONVERT_CROP"] == "1")
        return true
    }

    @MainActor private static var swept = false
    @MainActor private static var probeWindow: NSWindow?

    /// Copy and paste of print settings (FLXCONVERT_PASTE_TEST): a print with
    /// every kind of setting on the frame on screen, copied; pasted onto a
    /// frame not on screen that has its own film, rebate, crop, masks and
    /// print (the question answered yes), onto one whose question is answered
    /// no, and onto the frame on screen. Prints PASS or FAIL, then quits.
    @MainActor private static func pasteTest(_ model: ConvertModel) {
        guard model.frames.count >= 3, let a = model.selection,
              let i = model.frames.firstIndex(where: { $0.url == a }) else { print("paste test: needs three frames"); exit(1) }
        let b = model.frames[(i + 1) % model.frames.count].url, c = model.frames[(i + 2) % model.frames.count].url
        var failed = false
        func check(_ what: String, _ ok: Bool) { if !ok { failed = true }; print("paste test: \(what) \(ok ? "as it should be" : "WRONG")") }

        // The source: every print setting moved, and a film, rebate, crop and mask of its own.
        model.frame = FrameSettings()
        model.frame.exposure = 0.7; model.frame.brightness = 40; model.frame.grade = 3
        model.frame.shadowGrade = 0.2; model.frame.highlightGrade = -0.2; model.frame.shadows = 0.3
        model.frame.highlights = -0.25; model.frame.toe = 0.1; model.frame.shoulder = 0.15; model.frame.snap = 0.1
        model.frame.shadowCMY = CMYOffset(cyan: 0.02, magenta: 0, yellow: -0.01); model.frame.preflash = 0.05
        model.frame.filtration = Filtration(yellow: 6, magenta: -4)
        model.frame.sharpness = 0.4; model.frame.localContrast = 0.3
        model.frame.curves = PrintCurves(spec: "rgb:0,0 64,52 192,205 255,255")
        model.frame.filmStock = "kodak_gold_200"; model.frame.rebatePick = CGRect(x: 0.01, y: 0.02, width: 0.3, height: 0.03)
        model.frame.geometry.setStraighten(2)
        model.addMask(.gradient)
        let source = model.frame
        model.copyPrintSettings()
        check("copied without film, rebate, crop or masks",
              model.copiedPrint?.settings == source.printOnly && model.copiedPrint?.settings.masks.isEmpty == true
              && model.copiedPrint?.settings.filmStock == nil)

        // Onto a frame not on screen, with all of its own.
        var own = FrameSettings()
        own.exposure = -0.4; own.filmStock = "kodak_ektar_100"; own.rebatePick = CGRect(x: 0.5, y: 0.01, width: 0.2, height: 0.02)
        own.geometry.quarterTurns = 1; own.masks = source.masks + source.masks
        model.store(own, for: b)
        model.pasteAnswers = true
        model.pastePrintSettings(to: b)
        let pasted = model.settings(of: b)
        check("frame off screen takes the print", pasted.printOnly == source.printOnly)
        check("frame off screen keeps its film, rebate, crop and masks",
              pasted.filmStock == own.filmStock && pasted.rebatePick == own.rebatePick
              && pasted.geometry == own.geometry && pasted.masks == own.masks)

        // Answered no: nothing changes.
        var other = FrameSettings(); other.exposure = 0.3
        model.store(other, for: c)
        model.pasteAnswers = false
        model.pastePrintSettings(to: c)
        check("a frame whose question is answered no stays", model.settings(of: c) == other)

        // Onto the frame on screen.
        model.pasteAnswers = true
        model.selection = c
        model.pastePrintSettings()
        check("frame on screen takes the print", model.frame.printOnly == source.printOnly && model.frame.filmStock == nil
              && model.settings(of: c) == model.frame)
        print("paste test: \(failed ? "FAIL" : "PASS")")
        exit(failed ? 1 : 0)
    }

    /// The curves editor clicked and dragged as a hand would (FLXCONVERT_CURVE_TEST):
    /// the histogram and curves as The Print shows them, in a window of their
    /// own 300 points wide, given mouse events. A click on the straight curve
    /// adds a point and drags it up, a click below the curve adds a second,
    /// that one is dragged off the graph and let go, which takes it away, and
    /// the white end is pulled down.
    /// Prints each step's points and PASS or FAIL, then quits.
    @MainActor private static func curveTest(_ model: ConvertModel) {
        model.frame.curves = nil
        struct Probe: View {
            let model: ConvertModel
            var body: some View { VStack(spacing: 0) { PrintGraphs.of(model) }.frame(width: 300) }
        }
        let host = NSHostingView(rootView: Probe(model: model))
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        probeWindow = window
        // The graph is the bottom 176 points less the 6 below it, its plot 6 in.
        func at(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: 6 + 288 * x, y: 12 + 164 * y) }
        var clock = ProcessInfo.processInfo.systemUptime
        func send(_ type: NSEvent.EventType, _ p: CGPoint) {
            clock += 0.02
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: clock,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                window.sendEvent(e)
            }
        }
        func points() -> String {
            (model.frame.curves?.rgb ?? PrintCurves.straight)
                .map { String(format: "(%.2f, %.2f)", $0.x, $0.y) }.joined(separator: " ")
        }
        func near(_ want: [(Double, Double)]) -> Bool {
            let p = model.frame.curves?.rgb ?? PrintCurves.straight
            return p.count == want.count && zip(p, want).allSatisfy { abs($0.x - $1.0) < 0.02 && abs($0.y - $1.1) < 0.02 }
        }
        let strokes: [(from: (Double, Double), to: (Double, Double), want: [(Double, Double)])] = [
            ((0.5, 0.5), (0.5, 0.7), [(0, 0), (0.5, 0.7), (1, 1)]),
            ((0.25, 0.2), (0.25, 0.15), [(0, 0), (0.25, 0.15), (0.5, 0.7), (1, 1)]),
            ((0.25, 0.15), (0.25, -0.5), [(0, 0), (0.5, 0.7), (1, 1)]),
            ((1, 1), (1, 0.85), [(0, 0), (0.5, 0.7), (1, 0.85)]),
        ]
        var failed = false
        func stroke(_ k: Int) {
            guard k < strokes.count else {
                print("curve test: \(failed ? "FAIL" : "PASS")")
                exit(failed ? 1 : 0)
            }
            let s = strokes[k]
            let a = at(s.from.0, s.from.1), b = at(s.to.0, s.to.1)
            send(.leftMouseDown, a)
            var i = 0
            func drag() {
                i += 1
                let t = Double(i) / 4
                send(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                if i < 4 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drag() }; return }
                send(.leftMouseUp, b)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let ok = near(s.want)
                    if !ok { failed = true }
                    print("curve test, stroke \(k + 1): \(points()) \(ok ? "as it should be" : "WRONG")")
                    stroke(k + 1)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drag() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { stroke(0) }
    }
    @MainActor private static var soaked = false

    /// A restless user for `seconds` (FLXCONVERT_SOAK): every 0.3 s one of
    /// the next frame, a slider nudged, the loupe opened, moved or closed,
    /// Crop to Picture, the scan view, the crop tool, at random but the same
    /// every run; the memory in use every 10 s, so a leak shows as a rising
    /// line and a hang as the lines stopping.
    @MainActor private static func soak(_ model: ConvertModel, seconds: Double, done: @escaping () -> Void) {
        var seed: UInt64 = 0x5EED
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        let start = CFAbsoluteTimeGetCurrent()
        var lastReport = 0.0, actions = 0
        func report(_ elapsed: Double) {
            print(String(format: "soak %5.0f s: %.2f GB in use, %d actions, %d sidebar prints",
                         elapsed, Converter.footprint(), actions, model.thumbnails.images.count))
            fflush(stdout)
        }
        func step() {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            if elapsed - lastReport >= 10 { lastReport = elapsed; report(elapsed) }
            guard elapsed < seconds else { report(elapsed); model.loupeOn = false; done(); return }
            actions += 1
            switch next() % 12 {
            case 0, 1: model.select(offset: 1)
            case 2: if model.selection == model.frames.last?.url, let f = model.frames.first { model.selection = f.url }
            case 3: model.frame.exposure = Double(next() % 21) / 10 - 1
            case 4: model.frame.sharpness = Double(next() % 11) / 10
            case 5: model.frame.localContrast = Double(next() % 6) / 10
            case 6: model.loupeOn.toggle()
            case 7: model.moveLoupe(to: CGPoint(x: Double(next() % 100) / 100, y: Double(next() % 100) / 100))
            case 8: model.cropToPicture()
            case 9: model.showScan.toggle()
            case 10: model.isCropping.toggle()
            default: model.frame.grade = Double(next() % 5)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { step() }
        }
        step()
    }
    @MainActor private static var activity: NSObjectProtocol?

    /// Changes the exposure, waits for that print to reach the screen, and
    /// changes it again, 40 times (FLXCONVERT_SWEEP_COUNT): the round trip a
    /// dragged slider waits for (main thread, render, publication), free of
    /// timer throttling.
    @MainActor private static func sweep(_ model: ConvertModel, done: @escaping () -> Void) {
        var latencies: [Double] = []
        let n = max(env["FLXCONVERT_SWEEP_COUNT"].flatMap(Int.init) ?? 40, 2)
        var sent = CFAbsoluteTimeGetCurrent()
        var k = 0
        func step() {
            k += 1
            sent = CFAbsoluteTimeGetCurrent()
            model.frame.exposure = 1 + 0.5 * sin(Double(k) / 5)
        }
        // The main thread's own time, drawing included: from the first change
        // to half a second after the last print, when the screen has caught up.
        func mainThreadSeconds() -> Double {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return 0 }
            return Double(info.user_time.seconds + info.system_time.seconds)
                + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
        }
        let cpu0 = mainThreadSeconds()
        model.preview.onImage = {
            latencies.append(CFAbsoluteTimeGetCurrent() - sent)
            if latencies.count >= n {
                model.preview.onImage = nil
                let sorted = latencies.sorted()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print(String(format: "sweep: %d changes, round trip median %.1f ms, slowest %.1f ms, mean %.1f ms; main thread %.1f ms a change",
                                 n, sorted[n / 2] * 1000, sorted[n - 1] * 1000, latencies.reduce(0, +) / Double(n) * 1000,
                                 (mainThreadSeconds() - cpu0) / Double(n) * 1000))
                    done()
                }
            } else {
                DispatchQueue.main.async { step() }
            }
        }
        step()
    }

    @MainActor private static func poll(_ model: ConvertModel, tries: Int, crop: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if (model.preview.rendering || model.preview.image == nil) && tries < 60 { poll(model, tries: tries + 1, crop: crop); return }
            if model.loupeOn, model.loupeImage == nil || model.loupeLoading, tries < 90 { poll(model, tries: tries + 1, crop: crop); return }
            if crop, model.field != nil {
                model.cropToPicture { poll(model, tries: tries + 1, crop: false) }
                return
            }
            if let seconds = env["FLXCONVERT_SOAK"].flatMap(Double.init), !soaked {
                soaked = true
                soak(model, seconds: seconds) { poll(model, tries: tries + 1, crop: false) }
                return
            }
            if env["FLXCONVERT_SWEEP"] == "1", !swept {
                swept = true
                let delay = env["FLXCONVERT_SWEEP_DELAY"].flatMap(Double.init) ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    sweep(model) { poll(model, tries: tries + 1, crop: false) }
                }
                return
            }
            if env["FLXCONVERT_CURVE_TEST"] == "1" { curveTest(model); return }
            if env["FLXCONVERT_PASTE_TEST"] == "1" { pasteTest(model); return }
            if env["FLXCONVERT_MASK"] == "1", model.frame.masks.isEmpty, model.displayMap != nil {
                model.addMask(.gradient)
                model.addMask(.oval)
                poll(model, tries: tries + 1, crop: false); return
            }
            let wait = env["FLXCONVERT_WAIT"].flatMap(Double.init) ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + wait) {
                guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView else { exit(2) }
                let out = URL(fileURLWithPath: env["FLXCONVERT_SNAPSHOT"]!)
                // The window as the screen shows it, where capture is already
                // allowed (it asks nothing); otherwise drawn offscreen, which
                // leaves out the sidebar's material and the slider tracks.
                typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                if CGPreflightScreenCaptureAccess(),
                   let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                   let cg = unsafeBitCast(sym, to: WindowImage.self)(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                                                                     UInt32(window.windowNumber),
                                                                     CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue)?
                    .takeRetainedValue(), !CGSessionLocked.now {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: out)
                } else if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    // A locked screen captures as transparent: draw the window instead.
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out)
                }
                print("snapshot: \(model.baseNote) \(model.error ?? "")")
                exit(0)
            }
        }
    }
}

struct ContentView: View {
    @Bindable var model: ConvertModel
    @State private var inspector = true

    var body: some View {
        NavigationSplitView {
            Group { if SelfCheck.env["FLXCONVERT_NO_SIDEBAR"] == nil { FrameList(model: model, thumbnails: model.thumbnails) } }
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            // The inspector beside the canvas, as in FLX Film Lab, not in
            // SwiftUI's inspector column: that column runs up under the toolbar
            // in its own colour and breaks the bar where it starts.
            HStack(spacing: 0) {
                CanvasView(model: model, preview: model.preview)
                    .overlay(alignment: .bottomLeading) { ErrorNote(model: model) }
                if inspector && SelfCheck.env["FLXCONVERT_NO_INSPECTOR"] == nil {
                    Divider()
                    InspectorView(model: model)
                        .frame(width: 320)
                        // Not under the toolbar, which keeps one colour across.
                        .background(.ultraThinMaterial, ignoresSafeAreaEdges: [])
                }
            }
        }
        .navigationTitle(model.selectedFrame?.name ?? "FLX Film Convert")
        .navigationSubtitle(model.folder.map { "\($0.lastPathComponent) — \(model.rollTitle)" } ?? "")
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseFolder() } label: { Label("Open Roll", systemImage: "folder") }
                Picker("View", selection: $model.showScan) {
                    Text("Print").tag(false)
                    Text("Scan").tag(true)
                }
                .pickerStyle(.segmented)
                Button { model.turn(clockwise: false) } label: { Label("Turn Left", systemImage: "rotate.left") }
                Button { model.turn(clockwise: true) } label: { Label("Turn Right", systemImage: "rotate.right") }
                Toggle(isOn: $model.isCropping) { Label("Crop", systemImage: "crop") }
                ControlGroup {
                    Button { model.copyPrintSettings() } label: { Label("Copy Print Settings", systemImage: "doc.on.doc") }
                        .help("Copy this frame's print settings: The Print, Shadows & Highlights, its colour balance and regional colour, Detail, Bloom & Glow and the curves. Not its film, rebate, crop or masks. ⇧⌘C")
                        .disabled(model.selection == nil)
                    Button { model.pastePrintSettings() } label: { Label("Paste Print Settings", systemImage: "doc.on.clipboard") }
                        .help(model.copiedPrint.map { "Paste the print settings of \($0.source) onto this frame, which keeps its film, rebate, crop and masks. ⇧⌘V" }
                              ?? "Paste print settings copied from another frame. ⇧⌘V")
                        .disabled(model.copiedPrint == nil || model.selection == nil)
                } label: { Label("Print Settings", systemImage: "doc.on.doc") }
                Toggle(isOn: $model.loupeOn) { Label("Loupe", systemImage: "magnifyingglass") }
                    .help("The print at 100%, from the scan at full size. Drag it over the print. ⌘L")
                Button { inspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
    }
}

struct ErrorNote: View {
    var model: ConvertModel
    var body: some View {
        if let error = model.error {
            Text(error).font(.callout).padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(12)
        }
    }
}

struct FrameList: View {
    @Bindable var model: ConvertModel
    var thumbnails: Thumbnails

    var body: some View {
        Group {
            if model.frames.isEmpty {
                VStack(spacing: 12) {
                    Text("No roll open").foregroundStyle(.secondary)
                    Button("Open Roll…") { model.chooseFolder() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $model.selection) {
                        ForEach(model.frames) { frame in
                            FrameRow(frame: frame, thumbnails: thumbnails, note: model.frameNotes[frame.url])
                                .tag(frame.url).id(frame.url)
                                .contextMenu {
                                    Button("Copy Print Settings") { model.copyPrintSettings(from: frame.url) }
                                    Button(model.copiedPrint.map { "Paste Print Settings of \($0.source)" } ?? "Paste Print Settings") {
                                        model.pastePrintSettings(to: frame.url)
                                    }
                                    .disabled(model.copiedPrint == nil)
                                    Divider()
                                    Button("Use as Flat Field for This Roll") { model.useAsFlatField(frame.url) }
                                }
                        }
                    }
                    // The selected frame stays in view, whoever selected it.
                    .onChange(of: model.selection) { _, url in
                        if let url { proxy.scrollTo(url) }
                    }
                    .onAppear { if let url = model.selection { proxy.scrollTo(url) } }
                }
            }
        }
    }
}

/// One frame in the sidebar; it reads its own thumbnail, so a new one redraws
/// only its row.
struct FrameRow: View {
    let frame: ConvertModel.Frame
    var thumbnails: Thumbnails
    /// What the frame has of its own: a film, a filter pack.
    var note: String?

    var body: some View {
        HStack(spacing: 8) {
            if let thumb = thumbnails.images[frame.url] {
                Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 84, height: 56)
            } else {
                Rectangle().fill(.quaternary).frame(width: 84, height: 56)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(frame.name).font(.callout)
                if let note {
                    Text(note).font(.caption2).foregroundStyle(Color.accentColor).lineLimit(2)
                }
            }
        }
    }
}

/// Whether the screen is locked, when window captures come back transparent.
enum CGSessionLocked {
    static var now: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

extension NSWindow {
    @objc func selfCheckIsKey() -> Bool { true }
}

extension NSApplication {
    @objc func selfCheckIsActive() -> Bool { true }
}
