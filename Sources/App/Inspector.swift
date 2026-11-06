import SwiftUI
import AppKit

/// The controls, laid out as FLX Film Lab's stills inspector, with its names
/// and scales (-100...100 where FLX Film Lab uses them). The roll's controls
/// are what a darkroom printer sets once per roll, because they belong to
/// the film and its processing; the rest are this frame's print.
struct InspectorView: View {
    @Bindable var model: ConvertModel
    /// Print: everything that makes the print. Export: what is written with
    /// it, and where it goes.
    @AppStorage("inspectorTab") private var tab = "print"

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                Text("Print").tag("print")
                Text("Export").tag("export")
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
            ScrollView {
                // Lazy, so a change re-measures what shows, not the whole panel.
                LazyVStack(alignment: .leading, spacing: 0) {
                    if tab == "export" {
                        CaptureSection(model: model)
                        ExportSection(model: model)
                    } else {
                        RollSection(model: model)
                        BaseSection(model: model)
                        CropSection(model: model)
                        PrintSection(model: model)
                        ToneSection(model: model)
                        ColourSection(model: model)
                        DetailSection(model: model)
                        DodgeBurnSection(model: model)
                        EffectsSection(model: model)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
        }
        .controlSize(.small)
        .onAppear { if let t = SelfCheck.env["FLXCONVERT_TAB"] { tab = t } }
    }
}

/// What the pictures were shot with and when, written into the exports with
/// the film and the paper.
struct CaptureSection: View {
    @Bindable var model: ConvertModel

    var body: some View {
        PanelSection("Shot with", footer: "Written into every exported file. The film and the paper always are. A camera or lens given here replaces the scanning camera's, and the scan's exposure is left out; a date becomes the picture's, and the scan's becomes the date it was digitized.") {
            Text("Roll").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            FieldRow("Camera") {
                TextField("Camera", text: $model.capture.camera, prompt: Text("e.g. Nikon F3"))
            }
            FieldRow("Lens") {
                TextField("Lens", text: $model.capture.lens, prompt: Text("e.g. Nikkor 50mm f/1.4"))
            }
            DateRow(title: "Date", date: $model.capture.date, unset: "the scan's")
            FieldRow("EI") {
                TextField("EI", value: $model.capture.exposureIndex, format: .number,
                          prompt: Text(model.filmSpeed.map { "\($0), the film's speed" } ?? "the film's speed"))
            }
            FieldRow("Notes") {
                TextField("Notes", text: $model.capture.notes, prompt: Text("developer, lab, push…"), axis: .vertical)
                    .lineLimit(1...3)
            }
            Text("This frame").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 4)
            FieldRow("Lens") {
                TextField("Lens", text: Binding(get: { model.frameCapture.lens ?? "" },
                                                set: { model.frameCapture.lens = $0.isEmpty ? nil : $0 }),
                          prompt: Text(model.capture.lens.isEmpty ? "as the roll" : "as the roll: \(model.capture.lens)"))
            }
            DateRow(title: "Date", date: $model.frameCapture.date, unset: "as the roll")
            Text("Its caption").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 4)
            Text(model.exportCaption)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A label and its field, the labels lined up.
struct FieldRow<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            content.textFieldStyle(.roundedBorder).labelsHidden()
        }
    }
}

/// A date that may be left out: off shows what stands in for it.
struct DateRow: View {
    let title: String
    @Binding var date: Date?
    let unset: String

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Toggle(title, isOn: Binding(get: { date != nil }, set: { date = $0 ? (date ?? Date()) : nil }))
                .labelsHidden().toggleStyle(.checkbox)
            if let d = date {
                DatePicker(title, selection: Binding(get: { d }, set: { date = $0 }), displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field)
            } else {
                Text(unset).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}

struct RollSection: View {
    @Bindable var model: ConvertModel

    var body: some View {
        PanelSection("Roll", footer: "Film, paper, filtration and crossover hold for every frame of this folder.") {
            StockPickers(rollFilm: model.roll.filmStock, frameFilm: model.frame.filmStock,
                         rollFilmName: (try? PackLibrary.shared.pack(model.roll.filmStock))?.name ?? model.roll.filmStock,
                         paper: model.roll.printStock, defaultPaper: defaultPaperName,
                         films: model.films, papers: model.papers,
                         setRollFilm: { model.roll.filmStock = $0 },
                         setFrameFilm: { model.frame.filmStock = $0 },
                         setPaper: { model.roll.printStock = $0 })
                .equatable()
            FlatFieldRow(model: model)
        }
    }

    private var defaultPaperName: String {
        let target = model.filmPack?.targetPrint ?? ""
        return (try? PackLibrary.shared.pack(target))?.name ?? target
    }
}

/// The roll's flat field: optional, a frame of the bare light the user
/// chooses, switched on or off without forgetting it.
struct FlatFieldRow: View {
    @Bindable var model: ConvertModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Flat field", isOn: $model.roll.useFlatField)
                    .disabled(model.roll.flatField == nil)
                Spacer()
                Button("Choose…") { model.chooseFlatField() }
                if model.roll.flatField != nil {
                    Button("Clear") { model.roll.flatField = nil }
                }
            }
            Text(model.roll.flatField.map { URL(fileURLWithPath: $0).lastPathComponent }
                 ?? "None: the light's falloff comes from the rebate.")
                .font(.caption).foregroundStyle(.secondary)
            Text("A frame of the bare light, shot with this roll's camera, lens, aperture and holder, takes the light's falloff out exactly. A frame from the roll can also be chosen in the sidebar.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

/// The film and paper menus. Their menus are long and slow to rebuild, so
/// they compare by the choices they show and redraw only when one changes,
/// not with every slider.
struct StockPickers: View, Equatable {
    let rollFilm: String
    /// The film of this frame alone, where a folder holds more than one roll.
    let frameFilm: String?
    let rollFilmName: String
    let paper: String?
    let defaultPaper: String
    let films: [(title: String, entries: [PackIndexEntry])]
    let papers: [(title: String, entries: [PackIndexEntry])]
    let setRollFilm: (String) -> Void
    let setFrameFilm: (String?) -> Void
    let setPaper: (String?) -> Void

    static func == (a: StockPickers, b: StockPickers) -> Bool {
        a.rollFilm == b.rollFilm && a.frameFilm == b.frameFilm && a.paper == b.paper && a.defaultPaper == b.defaultPaper
    }

    var body: some View {
        Picker("Roll film", selection: Binding(get: { rollFilm }, set: setRollFilm)) {
            ForEach(films, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.entries) { Text($0.name).tag($0.stock) }
                }
            }
        }
        .help("The film of every frame in this folder, unless a frame has its own.")
        Picker("This frame", selection: Binding(get: { frameFilm }, set: setFrameFilm)) {
            Text("As the roll (\(rollFilmName))").tag(String?.none)
            ForEach(films, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.entries) { Text($0.name).tag(Optional($0.stock)) }
                }
            }
        }
        .help("For a folder that holds frames of more than one film: this frame prints as the film chosen here; the sidebar names it.")
        Picker("Paper", selection: Binding(get: { paper }, set: setPaper)) {
            Text("The film's own (\(defaultPaper))").tag(String?.none)
            ForEach(papers, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.entries) { Text($0.name).tag(Optional($0.stock)) }
                }
            }
        }
    }
}

struct BaseSection: View {
    @Bindable var model: ConvertModel

    var body: some View {
        PanelSection("Film base") {
            Text(model.baseNote.isEmpty ? "Measuring…" : model.baseNote)
                .font(.callout)
                .foregroundStyle(model.field == nil && model.frame.rebatePick == nil ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.tool == .pickRebate ? "Drag over the rebate…" : "Pick Rebate") {
                    model.tool = model.tool == .pickRebate ? .none : .pickRebate
                }
                if model.frame.rebatePick != nil {
                    Button("Use Film Edges") { model.frame.rebatePick = nil }
                }
            }
            Toggle("Show rebate strips", isOn: $model.showStrips)
            Toggle("Show the scan", isOn: $model.showScan)
        }
    }

}

struct CropSection: View {
    @Bindable var model: ConvertModel

    var body: some View {
        PanelSection("Crop & Straighten", footer: "The print's shape. The negative is read whole; the meter reads only what the crop keeps.") {
            HStack(spacing: 6) {
                Toggle(isOn: $model.isCropping) { Label("Crop", systemImage: "crop") }
                    .toggleStyle(.button)
                    .help("Show the whole frame with the crop on it, to drag its corners and edges (⌘R).")
                Picker("", selection: Binding(get: { geometry.aspect }, set: { model.setCropAspect($0) })) {
                    ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 104)
                .help("The crop's proportions. Original keeps the frame's own; Free has none.")
                Button { model.swapCropOrientation() } label: { Image(systemName: "rectangle.portrait.rotate") }
                    .buttonStyle(.borderless)
                    .disabled(geometry.aspect == .free)
                    .help("Stand the crop up, or lay it down.")
            }
            if geometry.aspect == .custom {
                HStack(spacing: 4) {
                    TextField("Width", value: Binding(get: { geometry.customWidth },
                                                      set: { model.setCustomAspect(width: $0, height: geometry.customHeight) }),
                              format: .number).frame(width: 52)
                    Text(":").foregroundStyle(.secondary)
                    TextField("Height", value: Binding(get: { geometry.customHeight },
                                                       set: { model.setCustomAspect(width: geometry.customWidth, height: $0) }),
                              format: .number).frame(width: 52)
                    Spacer()
                }
                .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                Button { model.turn(clockwise: false) } label: { Image(systemName: "rotate.left") }
                    .help("Turn a quarter to the left (⌘[).")
                Button { model.turn(clockwise: true) } label: { Image(systemName: "rotate.right") }
                    .help("Turn a quarter to the right (⌘]).")
                Button { model.flip(horizontal: true) } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Mirror left to right.")
                Button { model.flip(horizontal: false) } label: {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
                .help("Mirror top to bottom.")
                Spacer()
                Toggle(isOn: $model.isLevelling) { Label("Level", systemImage: "level") }
                    .toggleStyle(.button)
                    .help("Draw a line on the picture along a horizon, or along an upright, and the picture is levelled to it.")
            }
            .buttonStyle(.borderless)
            LabeledSlider(title: "Straighten", value: Binding(get: { geometry.straighten }, set: { model.setStraighten($0) }),
                          range: -FrameGeometry.maxStraighten...FrameGeometry.maxStraighten, step: 0.1,
                          format: "%+.1f°", reset: 0).equatable()
            Button("Crop to Picture") { model.cropToPicture() }
                .disabled(model.field == nil && model.frame.rebatePick == nil)
                .help("Level the print by the picture's own edges and cut it just inside them: found from the rebate and the gaps between frames, never from what the picture shows.")
            if let note = model.pictureNote {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ResetLink("Reset crop", enabled: geometry != FrameGeometry()) { model.resetGeometry() }
        }
    }


    private var geometry: FrameGeometry { model.frame.geometry }

}

struct PrintSection: View {
    @Bindable var model: ConvertModel

    var body: some View {
        PanelSection("The Print") {
            LabeledSlider(title: "Exposure", value: $model.frame.exposure, range: -4...4, step: 0.05,
                          format: "%+.2f stops", reset: 0, caption: "the enlarger timer; + is a lighter print").equatable()
            HStack {
                Spacer()
                Button("Meter") { model.meter() }
                    .help("Sets the exposure an enlarger meter would: the median density of what the crop keeps printed at the film's mid-grey. Brightness only, never colour.")
            }
            UnitSlider(title: "Brightness", value: $model.frame.brightness, perUnit: 0.002,
                       caption: "midtones lighter or darker; paper black and white stay put").equatable()
            // FLX Film Lab's Contrast: +100 is the hardest grade, R50; the soft
            // half runs to the film's own softest grade.
            let spec = Controls.contrast(softest: model.filmPack?.softestGrade ?? Constants.gradeMax)
            let standard = Double(model.filmPack?.defaultGrade ?? Constants.gradeReference)
            let grade = model.frame.grade ?? standard
            LabeledSlider(title: "Contrast", value: spec.binding(Binding(get: { model.frame.grade ?? standard },
                                                                         set: { model.frame.grade = $0 })),
                          range: spec.range, step: 1, format: "%+.0f", reset: spec.fromPhysical(standard),
                          resetAction: { model.frame.grade = nil },
                          caption: String(format: "+ is harder · paper grade R%.0f", grade)).equatable()
                .help(spec.help(.photographic, physical: grade))
            UnitSlider(title: "Shadow contrast", value: $model.frame.shadowGrade, perUnit: -0.4,
                       caption: "split grade: the shadows' own contrast").equatable()
            UnitSlider(title: "Highlight contrast", value: $model.frame.highlightGrade, perUnit: -0.4,
                       caption: "split grade: the highlights' own contrast").equatable()
            ResetLink("Reset print", enabled: !model.printIsDefault) { model.resetPrint() }
        }
    }

}

struct ToneSection: View {
    @Bindable var model: ConvertModel

    var body: some View {
        PanelSection("Shadows & Highlights") {
            UnitSlider(title: "Shadows", value: $model.frame.shadows, perUnit: 0.01).equatable()
            UnitSlider(title: "Highlights", value: $model.frame.highlights, perUnit: 0.01).equatable()
            UnitSlider(title: "Blacks", value: $model.frame.toe, perUnit: 0.01,
                       caption: "+ lifts shadow detail out of paper black").equatable()
            UnitSlider(title: "Blacks range", value: $model.frame.toeWidth, perUnit: 0.01, range: 10...300,
                       unit: "%", defaultPhysical: 1).equatable()
            UnitSlider(title: "Whites", value: $model.frame.shoulder, perUnit: -0.01,
                       caption: "− holds highlights back from paper white").equatable()
            UnitSlider(title: "Whites range", value: $model.frame.shoulderWidth, perUnit: 0.01, range: 10...300,
                       unit: "%", defaultPhysical: 1).equatable()
            UnitSlider(title: "Midtone contrast", value: $model.frame.snap, perUnit: 0.005).equatable()
            ResetLink("Reset tone", enabled: !model.toneIsDefault) { model.resetTone() }
        }
    }

}

struct ColourSection: View {
    @Bindable var model: ConvertModel

    /// A minus sign, not a hyphen, before a negative value.
    static func cc(_ format: String, _ v: Double) -> String {
        String(format: format, v + 0).replacingOccurrences(of: "-", with: "−")
    }
    static func cc2(_ format: String, _ a: Double, _ b: Double) -> String {
        String(format: format, (a + 0).rounded(), (b + 0).rounded()).replacingOccurrences(of: "-", with: "−")
    }

    var body: some View {
        PanelSection("Colour", footer: model.printsInSilver ? "A black-and-white paper prints in silver: there is no colour to balance."
                                      : "Colour balance moves the enlarger's real yellow and magenta filters; the regional colours work in density, which a filter cannot do. Nothing here is set from the pictures.") {
            if !model.printsInSilver {
                HStack {
                    Text("Colour balance").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Colour balance for", selection: Binding(get: { model.filtersThisFrame },
                                                                    set: { model.setFiltersThisFrame($0) })) {
                        Text("Roll").tag(false)
                        Text("This frame").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Roll: one balance for every frame of this folder without one of its own. This frame: a balance for this frame alone, starting from the roll's; Roll again gives it back the roll's.")
                }
                // FLX Film Lab's Temperature and Tint: the enlarger's yellow and
                // magenta filters, 0.4 CC a step, + warmer and more magenta.
                LabeledSlider(title: "Temperature", value: Controls.temperature.binding($model.filterY),
                              range: Controls.temperature.range, step: 1, format: "%+.0f", reset: 0,
                              caption: Self.cc("+ is warmer · yellow filter %+.1f CC", model.filterY)).equatable()
                    .help(Controls.temperature.help(.photographic, physical: model.filterY))
                LabeledSlider(title: "Tint", value: Controls.tint.binding($model.filterM),
                              range: Controls.tint.range, step: 1, format: "%+.0f", reset: 0,
                              caption: Self.cc("+ is more magenta · magenta filter %+.1f CC", model.filterM)).equatable()
                    .help(Controls.tint.help(.photographic, physical: model.filterM))
                if model.filtersThisFrame {
                    Text(Self.cc2("This frame's own balance; the roll's is Temperature %+.0f, Tint %+.0f.",
                                  Controls.temperature.fromPhysical(model.roll.filterY), Controls.tint.fromPhysical(model.roll.filterM)))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ResetLink("Reset colour balance", enabled: model.filterY != 0 || model.filterM != 0) {
                    model.resetFiltration()
                }
                DisclosureGroup("Colour crossover (roll)") {
                    Text("Each dye layer has its own curve. A filter only shifts a whole layer, so it cannot fix crossover — shadows one colour, highlights the complement. These can, for a film or a process whose layers do not track.")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    TrimRow(title: "Grade trim", trim: $model.roll.gradeTrim, range: -30...30)
                    TrimRow(title: "Toe trim", trim: $model.roll.toeTrim, range: -1...1)
                    TrimRow(title: "Shoulder trim", trim: $model.roll.shoulderTrim, range: -1...1)
                    TrimRow(title: "Snap trim", trim: $model.roll.snapTrim, range: -0.5...0.5)
                    ResetLink("Reset crossover", enabled: !model.crossoverIsDefault) { model.resetCrossover() }
                }
                Text("This frame").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 4)
                CMYSliders(title: "Shadow colour", offset: $model.frame.shadowCMY)
                CMYSliders(title: "Highlight colour", offset: $model.frame.highlightCMY)
            }
            UnitSlider(title: "Highlight protection", value: $model.frame.preflash, perUnit: 0.003, range: 0...100,
                       unit: "%", caption: "pre-flash: holds the highlights, the darkroom way").equatable()
            ResetLink(model.printsInSilver ? "Reset highlight protection" : "Reset this frame's colour",
                      enabled: !model.colourIsDefault) { model.resetColour() }
        }
    }

}

struct DodgeBurnSection: View {
    @Bindable var model: ConvertModel

    var body: some View {
        PanelSection("Dodge & Burn", footer: "Masks change print exposure and contrast where they lie, so they roll into paper black the way a real burn does.") {
            HStack(spacing: 6) {
                Button { model.addMask(.gradient) } label: { Label("Graduated", systemImage: "square.righthalf.filled") }
                Button { model.addMask(.oval) } label: { Label("Oval", systemImage: "circle") }
                Button { model.addMask(.polygon) } label: { Label("Polygon", systemImage: "pentagon") }
            }
            .buttonStyle(.bordered)
            if model.frame.masks.isEmpty {
                Text("Add a mask, then drag its points on the print. A graduated mask is the card's edge: full at the first handle, gone by the second; the middle handle moves both.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            // By identifier, not by position, so deleting a row is safe.
            ForEach(model.frame.masks.map(\.id), id: \.self) { id in
                MaskRow(mask: maskBinding(id), selected: model.selectedMask == id,
                        select: { model.selectedMask = id }, delete: { model.deleteMask(id) })
            }
            ResetLink("Remove all masks", enabled: !model.frame.masks.isEmpty) { model.removeAllMasks() }
        }
    }


    private func maskBinding(_ id: UUID) -> Binding<LocalMask> {
        Binding(get: { model.frame.masks.first(where: { $0.id == id }) ?? LocalMask() },
                set: { new in
                    if let i = model.frame.masks.firstIndex(where: { $0.id == id }) { model.frame.masks[i] = new }
                })
    }

}

/// NegPy's sharpening and CLAHE, on the print's lightness only, so they
/// change no colour.
struct DetailSection: View {
    @Bindable var model: ConvertModel

    var body: some View {
        PanelSection("Detail", footer: "Both work on the print's lightness alone: the film's colour stays as it is. The radius is in pixels of the scan at full size, so a fitted preview shows only part of the sharpening; the loupe (⌘L) shows it at 100%.") {
            UnitSlider(title: "Sharpness", value: $model.frame.sharpness, perUnit: 0.01, range: 0...300, unit: "%",
                       caption: "unsharp mask, halos held to the pixels round it").equatable()
            LabeledSlider(title: "Radius", value: $model.frame.sharpenRadius, range: 0.3...5, step: 0.1,
                          format: "%.1f px", reset: 1, caption: "how fine the detail it sharpens").equatable()
            UnitSlider(title: "Masking", value: $model.frame.sharpenMasking, perUnit: 0.01, range: 0...100, unit: "%",
                       caption: "spares flat areas and grain").equatable()
            UnitSlider(title: "Local contrast (CLAHE)", value: $model.frame.localContrast, perUnit: 0.01,
                       range: 0...100, unit: "%",
                       caption: "evens tone out in an 8 × 8 grid over the print, limited").equatable()
            ResetLink("Reset detail", enabled: !model.detailIsDefault) { model.resetDetail() }
        }
    }
}

struct EffectsSection: View {
    @Bindable var model: ConvertModel

    var body: some View {
        PanelSection("Bloom & Glow", expanded: false) {
            Toggle("Bloom", isOn: look.bloom.enabled)
            if look.wrappedValue.bloom.enabled {
                LabeledSlider(title: "Amount", value: look.bloom.amount, range: 0...200, step: 1, format: "%.0f", reset: 100).equatable()
                LabeledSlider(title: "Size", value: look.bloom.size, range: 0...100, step: 1, format: "%.0f", reset: 45).equatable()
                LabeledSlider(title: "Threshold", value: look.bloom.threshold, range: 0...100, step: 1, format: "%.0f", reset: 80).equatable()
            }
            Toggle("Glow", isOn: look.glow.enabled)
            if look.wrappedValue.glow.enabled {
                LabeledSlider(title: "Amount", value: look.glow.amount, range: 0...100, step: 1, format: "%.0f", reset: 30).equatable()
                LabeledSlider(title: "Size", value: look.glow.size, range: 0...100, step: 1, format: "%.0f", reset: 40).equatable()
                LabeledSlider(title: "Threshold", value: look.glow.threshold, range: 0...100, step: 1, format: "%.0f", reset: 50).equatable()
            }
            ResetLink("Reset bloom & glow", enabled: model.frame.effects != nil) { model.frame.effects = nil }
        }
    }


    private static var offLook: GlowLook {
        var g = GlowLook()
        g.bloom.enabled = false
        g.glow.enabled = false
        g.halation.enabled = false
        return g
    }


    private var look: Binding<GlowLook> {
        Binding(get: { model.frame.effects ?? Self.offLook },
                set: { model.frame.effects = ($0.bloom.enabled || $0.glow.enabled) ? $0 : nil })
    }

}

struct ExportSection: View {
    @Bindable var model: ConvertModel

    var body: some View {
        PanelSection("Export") {
            Picker("Format", selection: $model.exportFormat) {
                ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Size", selection: $model.exportSize) {
                Text("Camera's full size").tag(0)
                Text("6000 px long edge").tag(6000)
                Text("4000 px long edge").tag(4000)
                Text("2400 px long edge").tag(2400)
            }
            Picker("Colour space", selection: $model.outputColorSpace) {
                ForEach(model.colorSpaces, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Button("Export Frame…") { model.exportFrame() }.disabled(model.selection == nil)
                Button("Export Roll…") { model.exportRoll() }.disabled(model.frames.isEmpty)
            }
            if let status = model.exportStatus {
                Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One mask: its name, on/off and delete; selected, its controls.
struct MaskRow: View {
    @Binding var mask: LocalMask
    let selected: Bool
    let select: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: mask.shape == .gradient ? "square.righthalf.filled"
                                  : mask.shape == .oval ? "circle" : "pentagon")
                    .foregroundStyle(.secondary)
                Button(mask.name, action: select)
                    .buttonStyle(.plain)
                    .fontWeight(selected ? .semibold : .regular)
                Spacer()
                Toggle("", isOn: $mask.enabled).labelsHidden()
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            if selected {
                UnitSlider(title: "Exposure", value: $mask.stops, perUnit: -0.02, defaultPhysical: 0.5,
                           caption: "+ dodges, − burns (±2 stops)").equatable()
                UnitSlider(title: "Contrast", value: $mask.grade, perUnit: -0.3,
                           caption: "prints this area through another grade").equatable()
                LabeledSlider(title: "Feather", value: $mask.feather, range: 0...0.25, step: 0.005,
                              format: "%.3f", reset: 0.04).equatable()
                Toggle("Invert", isOn: $mask.inverted)
                ResetLink("Reset this mask", enabled: mask.stops != 0.5 || mask.grade != 0 || mask.feather != 0.04 || mask.inverted) {
                    mask.stops = 0.5; mask.grade = 0; mask.feather = 0.04; mask.inverted = false
                }
            }
        }
    }
}

/// A slider in FLX Film Lab's units: shown as -100...100 (or `range`), stored
/// as the engine's physical value, `perUnit` per unit. Rows compare by what
/// they show, so moving one slider redraws that row alone.
struct UnitSlider: View, Equatable {
    static func == (a: UnitSlider, b: UnitSlider) -> Bool {
        a.title == b.title && a.value == b.value && a.perUnit == b.perUnit && a.range == b.range && a.caption == b.caption
    }

    let title: String
    @Binding var value: Double
    let perUnit: Double
    var range: ClosedRange<Double> = -100...100
    var unit = ""
    var defaultPhysical: Double = 0
    var caption: String?

    var body: some View {
        LabeledSlider(title: title, value: Binding(get: { value / perUnit + 0 }, set: { value = $0 * perUnit }),
                      range: range, step: 1, format: unit == "%" ? "%.0f%%" : "%+.0f" + unit,
                      reset: defaultPhysical / perUnit, caption: caption).equatable()
    }
}

/// A slider with its value, a double-click reset and an optional caption, as
/// FLX Film Lab's ParamSlider: the title brightens, with a dot, while the value
/// is off its default, and a double-click on the slider puts it back.
struct LabeledSlider: View, Equatable {
    static func == (a: LabeledSlider, b: LabeledSlider) -> Bool {
        a.title == b.title && a.value == b.value && a.range == b.range && a.format == b.format
            && a.caption == b.caption && a.reset == b.reset
    }

    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Rounds what the slider sets; the slider itself is continuous, as FLX
    /// Film Lab's are.
    let step: Double
    let format: String
    /// The default a double-click returns to.
    var reset: Double?
    /// Runs instead of setting `reset`, where the default is not a stored value.
    var resetAction: (() -> Void)?
    var caption: String?

    private var isModified: Bool { reset.map { abs(value - $0) > 1e-9 } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(isModified ? Color.primary : Color.secondary)
                if isModified { Circle().frame(width: 4, height: 4).foregroundStyle(Color.accentColor) }
                Spacer()
                Text(String(format: format, value + 0)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .trailing)
            }
            ResettingSlider(value: Binding(get: { value },
                                           set: { value = step > 0 ? ($0 / step).rounded() * step : $0 }),
                            range: range) {
                withAnimation(.easeOut(duration: 0.15)) {
                    if let resetAction { resetAction() } else if let reset { value = reset }
                }
            }
            if let caption { Text(caption).font(.caption2).foregroundStyle(.tertiary) }
        }
        .help("Double-click the slider to reset.")
    }
}

/// One curve trim per dye layer.
struct TrimRow: View {
    let title: String
    @Binding var trim: RGBTrim
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            channel("R", $trim.red, .red)
            channel("G", $trim.green, .green)
            channel("B", $trim.blue, .blue)
        }
    }

    private func channel(_ name: String, _ v: Binding<Double>, _ colour: Color) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.caption2.monospaced()).foregroundStyle(colour).frame(width: 12)
            ResettingSlider(value: v, range: range) { withAnimation(.easeOut(duration: 0.15)) { v.wrappedValue = 0 } }
                .help("Double-click the slider to reset.")
            Text(String(format: range.upperBound >= 10 ? "%+.0f" : "%+.2f", v.wrappedValue))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
        }
    }
}

/// Cyan, magenta and yellow in CC, for one tonal region.
struct CMYSliders: View {
    let title: String
    @Binding var offset: CMYOffset

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            channel("C", $offset.cyan, .cyan)
            channel("M", $offset.magenta, .pink)
            channel("Y", $offset.yellow, .yellow)
        }
    }

    private func channel(_ name: String, _ v: Binding<Double>, _ colour: Color) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.caption2.monospaced()).foregroundStyle(colour).frame(width: 12)
            ResettingSlider(value: v, range: -30...30) { withAnimation(.easeOut(duration: 0.15)) { v.wrappedValue = 0 } }
                .help("Double-click the slider to reset.")
            Text(String(format: "%+.1f", v.wrappedValue)).font(.caption2).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
        }
    }
}

/// A slider that a double-click puts back, as FLX Film Lab's (UI/Controls.swift):
/// the click count is read from the event that starts or ends the drag, so
/// the slider itself carries no gesture that would hold it back.
struct ResettingSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let reset: () -> Void
    @State private var startedOnDoubleClick = false

    var body: some View {
        Slider(value: $value, in: range, onEditingChanged: { editing in
            let event = NSApp.currentEvent
            let isClick = event?.type == .leftMouseDown || event?.type == .leftMouseUp
            let doubleClick = isClick && (event?.clickCount ?? 0) >= 2
            if editing {
                startedOnDoubleClick = doubleClick
            } else if startedOnDoubleClick || doubleClick {
                startedOnDoubleClick = false
                reset()
            }
        })
        .labelsHidden()
    }
}

/// A section's reset, as FLX Film Lab's: a small link, greyed out while there
/// is nothing to reset.
struct ResetLink: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(title) { withAnimation(.easeOut(duration: 0.15)) { action() } }
            .buttonStyle(.link)
            .font(.system(size: 10))
            .disabled(!enabled)
            .padding(.top, 2)
    }
}

/// A collapsible inspector section, as FLX Film Lab's (UI/Controls.swift):
/// a light stack rather than a Form, which re-measured every row whenever one
/// value's text changed.
struct PanelSection<Content: View>: View {
    let title: String
    var footer: String?
    @State private var expanded: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, footer: String? = nil, expanded: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self._expanded = State(initialValue: expanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .padding(.bottom, expanded ? 6 : 2)
            if expanded {
                VStack(alignment: .leading, spacing: 6) { content() }
                if let footer {
                    Text(footer)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().opacity(0.4).padding(.top, 8)
        }
    }
}
