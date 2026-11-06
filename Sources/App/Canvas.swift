import SwiftUI

/// The print (or the scan), fitted to the view, with what is measured and
/// drawn on it: the rebate strips, a picked rebate, the crop while it is being
/// edited, and the dodge-and-burn masks. Everything is stored in frame
/// fractions and shown through `displayMap`, where the image on screen comes
/// from in the frame, so it holds on a turned, levelled or cropped print.
struct CanvasView: View {
    @Bindable var model: ConvertModel
    var preview: Preview
    @State private var pickStart: CGPoint?
    @State private var pickNow: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let rect = fitted(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                if let image = preview.image {
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: rect.width, height: rect.height)
                            .onTapGesture { model.selectedMask = nil }
                        Canvas { ctx, _ in drawOverlays(&ctx, size: rect.size) }
                            .allowsHitTesting(false)
                        if model.isCropping {
                            CropOverlay(model: model, size: rect.size)
                        } else if !model.showScan && model.tool == .none {
                            MaskOverlay(masks: $model.frame.masks, gradients: .constant([]),
                                        selected: $model.selectedMask,
                                        frame: CGRect(origin: .zero, size: rect.size), map: model.displayMap)
                                .clipped()
                        }
                        if model.tool == .pickRebate {
                            Color.clear.contentShape(Rectangle()).gesture(pick(size: rect.size))
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                }
                if model.loupeOn, preview.image != nil, !model.showScan {
                    LoupeView(model: model, print: rect)
                }
                if preview.rendering {
                    ProgressView().controlSize(.small).padding(10)
                }
            }
            .coordinateSpace(name: "canvas")
        }
    }

    private var aspect: CGFloat {
        guard let m = model.displayMap else { return 1.5 }
        return CGFloat(m.outputWidth) / CGFloat(max(m.outputHeight, 1))
    }

    private func fitted(in size: CGSize) -> CGRect {
        let margin: CGFloat = 16
        let avail = CGSize(width: max(size.width - 2 * margin, 10), height: max(size.height - 2 * margin, 10))
        var w = avail.width, h = w / aspect
        if h > avail.height { h = avail.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    // Frame fractions <-> points on the image.
    private func toView(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        guard let map = model.displayMap else { return CGPoint(x: p.x * size.width, y: p.y * size.height) }
        let o = map.outputPoint(fromNormalised: p)
        return CGPoint(x: o.x / CGFloat(map.outputWidth) * size.width, y: o.y / CGFloat(map.outputHeight) * size.height)
    }
    private func toFrame(_ v: CGPoint, _ size: CGSize) -> CGPoint {
        guard let map = model.displayMap else { return CGPoint(x: v.x / size.width, y: v.y / size.height) }
        return map.normalisedSource(fromOutput: CGPoint(x: v.x / size.width * CGFloat(map.outputWidth),
                                                        y: v.y / size.height * CGFloat(map.outputHeight)))
    }

    // MARK: Drawing

    private func drawOverlays(_ ctx: inout GraphicsContext, size: CGSize) {
        let accent = Color.accentColor
        if model.showStrips, model.frame.rebatePick == nil, let field = model.field {
            for (p0, p1, half) in field.stripLines() {
                let n = field.vertical ? CGPoint(x: half, y: 0) : CGPoint(x: 0, y: half)
                var band = Path()
                band.addLines([CGPoint(x: p0.x - n.x, y: p0.y - n.y), CGPoint(x: p1.x - n.x, y: p1.y - n.y),
                               CGPoint(x: p1.x + n.x, y: p1.y + n.y), CGPoint(x: p0.x + n.x, y: p0.y + n.y)]
                    .map { toView($0, size) })
                band.closeSubpath()
                ctx.fill(band, with: .color(accent.opacity(0.35)))
                ctx.stroke(band, with: .color(accent), lineWidth: 1)
            }
        }
        if let pick = model.frame.rebatePick {
            var p = Path()
            p.addLines([CGPoint(x: pick.minX, y: pick.minY), CGPoint(x: pick.maxX, y: pick.minY),
                        CGPoint(x: pick.maxX, y: pick.maxY), CGPoint(x: pick.minX, y: pick.maxY)].map { toView($0, size) })
            p.closeSubpath()
            ctx.stroke(p, with: .color(accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        if let s = pickStart, let e = pickNow {
            let r = CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(e.x - s.x), height: abs(e.y - s.y))
            ctx.stroke(Path(r), with: .color(accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }

    // MARK: Picking the rebate

    /// A rectangle dragged over the rebate: its median is the base.
    private func pick(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                if pickStart == nil { pickStart = g.startLocation }
                pickNow = g.location
            }
            .onEnded { g in
                defer { pickStart = nil; pickNow = nil }
                let a = toFrame(g.startLocation, size), b = toFrame(g.location, size)
                let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                guard r.width > 0.002, r.height > 0.002 else { return }
                model.frame.rebatePick = r
                model.tool = .none
            }
    }
}

/// The print at 100% under a square that is dragged over it: one pixel of the
/// full-size print to one pixel of the screen. It stands over the part it
/// shows, as a loupe on a light table does.
struct LoupeView: View {
    var model: ConvertModel
    /// Where the fitted print lies in the canvas.
    let print: CGRect
    @Environment(\.displayScale) private var displayScale
    @State private var grab: CGSize?
    private let side: CGFloat = 300

    /// One pixel of the print to one of the screen: asks again when the
    /// screen's scale is not what the first request assumed.
    private func size() {
        let px = Int(side * displayScale)
        guard model.loupePixels != (px, px) else { return }
        model.loupePixels = (px, px)
        model.requestLoupe()
    }

    var body: some View {
        let c = model.loupeCentre
        let at = CGPoint(x: print.minX + c.x * print.width, y: print.minY + c.y * print.height)
        ZStack {
            if let image = model.loupeImage {
                Image(decorative: image, scale: displayScale)
                    .interpolation(.none)
                    .frame(width: side, height: side)
            } else {
                Color.black.opacity(0.6)
            }
            if model.loupeLoading {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the scan at full size…").font(.caption).foregroundStyle(.white)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
        .overlay(alignment: .bottomTrailing) {
            Text("100%").font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white).padding(6)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .contentShape(Rectangle())
        .position(at)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                .onChanged { g in
                    // Held where it was grabbed, not jumping to the cursor.
                    let offset = grab ?? CGSize(width: g.startLocation.x - at.x, height: g.startLocation.y - at.y)
                    grab = offset
                    let p = CGPoint(x: g.location.x - offset.width, y: g.location.y - offset.height)
                    model.moveLoupe(to: CGPoint(x: (p.x - print.minX) / max(print.width, 1),
                                                y: (p.y - print.minY) / max(print.height, 1)))
                }
                .onEnded { _ in grab = nil }
        )
        .onAppear { size() }
        .onChange(of: displayScale) { size() }
        .help("The print at 100%. Drag it over the print; ⌘L hides it.")
    }
}
