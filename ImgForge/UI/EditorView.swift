import SwiftUI
import PhotosUI
import Observation

@Observable
@MainActor
final class EditorStore {

    enum Panel: String, CaseIterable, Identifiable {
        case crop = "Recortar"
        case adjust = "Ajustes"
        case size = "Tamaño"
        var id: String { rawValue }
    }

    var source: UIImage?
    var preview: UIImage?
    var panel: Panel = .crop

    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var ratio: CGFloat?
    var adjustments = Adjustments.Options() { didSet { schedulePreview() } }
    var resize = Resizer.Options()
    var lockAspect = true
    var export = Exporter.Settings()

    /// Mientras el usuario no fije una medida, el tamaño de salida sigue
    /// al recorte. Sin esto, recortar y exportar volvía a estirar el
    /// recorte hasta las medidas originales, que es pura pérdida.
    var sizeTouched = false

    private(set) var isWorking = false
    var error: String?
    var status: String?

    @ObservationIgnored private var previewTask: Task<Void, Never>?

    // MARK: - Historial

    struct Snapshot: Equatable {
        var crop: CGRect
        var ratio: CGFloat?
        var adjustments: Adjustments.Options
        var resize: Resizer.Options
        var sizeTouched: Bool
    }

    @ObservationIgnored private var undoStack: [Snapshot] = []
    @ObservationIgnored private var redoStack: [Snapshot] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private var snapshot: Snapshot {
        Snapshot(crop: crop, ratio: ratio, adjustments: adjustments,
                 resize: resize, sizeTouched: sizeTouched)
    }

    private func restore(_ s: Snapshot) {
        suspendHistory = true
        crop = s.crop
        ratio = s.ratio
        adjustments = s.adjustments
        resize = s.resize
        sizeTouched = s.sizeTouched
        suspendHistory = false
        schedulePreview()
    }

    @ObservationIgnored private var suspendHistory = false

    /// Se llama antes de cada cambio que el usuario querría deshacer:
    /// al soltar un deslizador, al tocar un botón, no en cada fotograma.
    func commit() {
        guard !suspendHistory else { return }
        let s = snapshot
        guard undoStack.last != s else { return }
        undoStack.append(s)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
        status = "Deshecho."
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
        status = "Rehecho."
    }

    // MARK: - Mejora automática

    func autoEnhance() {
        guard let src = preview ?? source else { return }
        commit()
        do {
            adjustments = try AutoEnhance.suggest(for: src, keeping: adjustments)
            status = "Mejora automática aplicada."
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Proporción de la imagen ya recortada: de ahí sale el candado.
    var croppedAspect: CGFloat {
        guard let cg = source?.cgImage else { return 1 }
        let w = CGFloat(cg.width) * crop.width
        let h = CGFloat(cg.height) * crop.height
        return h > 0 ? w / h : 1
    }

    var croppedSize: String {
        guard let cg = source?.cgImage else { return "—" }
        return "\(Int(CGFloat(cg.width) * crop.width)) × \(Int(CGFloat(cg.height) * crop.height))"
    }

    func load(_ image: UIImage) {
        source = image.normalizedOrientation()
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        ratio = nil
        adjustments = Adjustments.Options()
        error = nil
        status = nil
        sizeTouched = false
        syncSizeToCrop()
        schedulePreview()
    }

    /// Tamaño nativo del recorte, en píxeles reales de la fuente.
    var croppedPixels: (width: Int, height: Int) {
        guard let cg = source?.cgImage else { return (0, 0) }
        let quarters = ((adjustments.rotationQuarters % 4) + 4) % 4
        let w = Int((CGFloat(cg.width) * crop.width).rounded())
        let h = Int((CGFloat(cg.height) * crop.height).rounded())
        return quarters % 2 == 1 ? (h, w) : (w, h)
    }

    func syncSizeToCrop() {
        guard !sizeTouched else { return }
        let p = croppedPixels
        guard p.width > 0, p.height > 0 else { return }
        resize.width = p.width
        resize.height = p.height
    }

    func cropChanged() {
        syncSizeToCrop()
        schedulePreview()
    }

    /// Vuelve al tamaño nativo del recorte: sin remuestreo, sin pérdida.
    func useNativeSize() {
        sizeTouched = false
        syncSizeToCrop()
        status = "Tamaño nativo: \(resize.width) × \(resize.height)"
    }

    func reset() {
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        ratio = nil
        adjustments = Adjustments.Options()
        sizeTouched = false
        syncSizeToCrop()
        undoStack.removeAll()
        redoStack.removeAll()
        status = "Ajustes restablecidos."
        schedulePreview()
    }

    /// El candado: al escribir un lado, el otro se deduce.
    func widthChanged(_ value: Int) {
        sizeTouched = true
        resize.width = max(1, value)
        guard lockAspect else { return }
        resize.height = max(1, Int((CGFloat(resize.width) / croppedAspect).rounded()))
    }

    func heightChanged(_ value: Int) {
        sizeTouched = true
        resize.height = max(1, value)
        guard lockAspect else { return }
        resize.width = max(1, Int((CGFloat(resize.height) * croppedAspect).rounded()))
    }

    func applyPreset(_ p: Resizer.SizePreset) {
        sizeTouched = true
        resize.width = p.width
        resize.height = p.height
        status = p.name
    }

    func setRatio(_ r: CGFloat?) {
        ratio = r
        guard let r, let cg = source?.cgImage else { return }

        // Marco centrado, lo más grande que entre con esa proporción.
        let imageAspect = CGFloat(cg.width) / CGFloat(cg.height)
        var w: CGFloat = 1, h: CGFloat = 1
        if r > imageAspect {
            h = imageAspect / r
        } else {
            w = r / imageAspect
        }
        crop = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
        cropChanged()
    }

    /// Avisa cuando la medida pedida obliga a inventar o tirar píxeles.
    var resampleNote: String? {
        guard sizeTouched else { return nil }
        let n = croppedPixels
        guard n.width > 0 else { return nil }
        if resize.width == n.width && resize.height == n.height { return nil }
        if resize.width > n.width || resize.height > n.height {
            return "Mayor que el recorte: se interpola. Usa Forja para ampliar con el modelo."
        }
        return "Menor que el recorte (\(n.width) × \(n.height)): se reduce."
    }

    // MARK: - Vista previa

    func schedulePreview() {
        guard let src = source else { return }
        previewTask?.cancel()

        let opts = adjustments
        let area = crop
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            guard !Task.isCancelled else { return }

            let out = await Task.detached(priority: .userInitiated) {
                try? Adjustments.apply(src, options: opts, crop: area, maxEdge: 1400)
            }.value

            guard !Task.isCancelled, let self else { return }
            if let out { self.preview = out }
        }
    }

    // MARK: - Exportar

    func render() async -> URL? {
        guard let src = source else {
            error = ForgeError.noImage.localizedDescription
            return nil
        }
        isWorking = true
        error = nil
        defer { isWorking = false }

        let opts = adjustments
        let area = crop
        let settings = export
        var size = resize
        let native = croppedPixels

        // Sin medida fija, se exporta el recorte tal cual: ni un remuestreo.
        if !sizeTouched || size.width <= 0 || size.height <= 0 {
            size.width = max(1, native.width)
            size.height = max(1, native.height)
        }

        do {
            let url = try await Task.detached(priority: .userInitiated) {
                let edited = try Adjustments.apply(src, options: opts, crop: area)

                let needsResize = edited.cgImage.map {
                    $0.width != size.width || $0.height != size.height
                } ?? false
                let final = needsResize
                    ? try Resizer.run(edited, options: size)
                    : edited

                return try Exporter.write(
                    final, settings: settings,
                    stem: "imgforge_edit_\(Int(Date().timeIntervalSince1970))")
            }.value

            status = "\(size.width) × \(size.height) · \(settings.format.rawValue) listo."
            return url
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

// MARK: - Vista

struct EditorView: View {
    @State private var store = EditorStore()
    @State private var pick: PhotosPickerItem?
    @State private var shareURL: URL?
    @State private var saving = false

    private let ratios: [(String, CGFloat?)] = [
        ("Libre", nil), ("1:1", 1), ("4:5", 0.8), ("3:2", 1.5),
        ("16:9", 16.0 / 9), ("9:16", 9.0 / 16)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                canvas
                controls
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(selection: $pick, matching: .images) {
                        Label("Cargar", systemImage: "photo.badge.plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Restablecer") { store.reset() }
                        .disabled(store.source == nil)
                }
            }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let img = UIImage(data: data) else {
                        store.error = ForgeError.decodeFailed.localizedDescription
                        return
                    }
                    store.load(img)
                }
            }
            .sheet(item: Binding(get: { shareURL.map(SharedURL.init) },
                                 set: { shareURL = $0?.url })) { item in
                ShareSheet(urls: [item.url])
            }
        }
    }

    @ViewBuilder
    private var canvas: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)

            if let src = store.source {
                if store.panel == .crop {
                    CropOverlay(image: src, rect: $store.crop, ratio: store.ratio)
                        .padding(12)
                        .onChange(of: store.crop) { _, _ in store.cropChanged() }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 6)
                                .onEnded { _ in store.commit() }
                        )
                } else if let p = store.preview {
                    Image(uiImage: p)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                }
            } else {
                ContentUnavailableView {
                    Label("Ninguna imagen", systemImage: "slider.horizontal.below.rectangle")
                } description: {
                    Text("Carga una foto para recortarla, ajustarla y exportarla a la medida que necesites.")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var controls: some View {
        if store.source != nil {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Button { store.undo() } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 44, height: 36)
                    }
                    .disabled(!store.canUndo)
                    .accessibilityLabel("Deshacer")

                    Button { store.redo() } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .frame(width: 44, height: 36)
                    }
                    .disabled(!store.canRedo)
                    .accessibilityLabel("Rehacer")

                    Spacer()

                    Button { store.autoEnhance() } label: {
                        Label("Automático", systemImage: "wand.and.stars")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                }

                Picker("Panel", selection: $store.panel) {
                    ForEach(EditorStore.Panel.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                ScrollView {
                    switch store.panel {
                    case .crop:   cropPanel
                    case .adjust: adjustPanel
                    case .size:   sizePanel
                    }
                }
                .frame(maxHeight: 250)

                if let e = store.error {
                    Text(e).font(.footnote).foregroundStyle(.red)
                } else if let s = store.status {
                    Text(s).font(.footnote).foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            if let url = await store.render() {
                                saving = true
                                store.status = await PhotoSaver.save(urls: [url]).message
                                saving = false
                            }
                        }
                    } label: {
                        Label("Guardar", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isWorking || saving)

                    Button {
                        Task { shareURL = await store.render() }
                    } label: {
                        if store.isWorking {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 30)
                        } else {
                            Label("Exportar", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 30)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isWorking)
                }
                .controlSize(.large)
            }
            .padding(16)
            .background(.bar)
        }
    }

    private var cropPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Proporción").font(.subheadline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ratios, id: \.0) { name, value in
                        Button(name) { store.commit(); store.setRatio(value) }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(
                                store.ratio == value
                                    ? Color.accentColor.opacity(0.18)
                                    : Color(.tertiarySystemFill),
                                in: Capsule())
                    }
                }
            }
            .scrollClipDisabled()

            Divider()

            HStack(spacing: 10) {
                Button {
                    store.commit()
                    store.adjustments.rotationQuarters -= 1
                } label: {
                    Image(systemName: "rotate.left").frame(maxWidth: .infinity, minHeight: 30)
                }
                Button {
                    store.commit()
                    store.adjustments.rotationQuarters += 1
                } label: {
                    Image(systemName: "rotate.right").frame(maxWidth: .infinity, minHeight: 30)
                }
                Button {
                    store.commit()
                    store.adjustments.flipHorizontal.toggle()
                } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
            }
            .buttonStyle(.bordered)

            labeled("Enderezar", String(format: "%.1f°", store.adjustments.straighten)) {
                Slider(value: $store.adjustments.straighten, in: -15...15, step: 0.5)
            }

            LabeledContent("Recorte", value: store.croppedSize).font(.footnote)
        }
        .padding(.horizontal, 2)
    }

    private var adjustPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            group("Tono") {
                slider("Exposición", $store.adjustments.exposure, -2...2, "%.2f")
                slider("Contraste", $store.adjustments.contrast, 0.5...1.5, "%.2f")
                slider("Altas luces", $store.adjustments.highlights, 0...1, "%.2f")
                slider("Sombras", $store.adjustments.shadows, -1...1, "%.2f")
                slider("Negros", $store.adjustments.blackPoint, 0...0.2, "%.3f")
            }
            group("Color") {
                slider("Saturación", $store.adjustments.saturation, 0...2, "%.2f")
                slider("Intensidad", $store.adjustments.vibrance, -1...1, "%.2f")
                slider("Temperatura", $store.adjustments.temperature, 3000...9000, "%.0f K")
                slider("Matiz", $store.adjustments.tint, -100...100, "%.0f")
            }
            group("Detalle") {
                slider("Enfoque", $store.adjustments.sharpness, 0...2, "%.2f")
                slider("Ruido", $store.adjustments.noiseReduction, 0...0.1, "%.3f")
            }
        }
        .padding(.horizontal, 2)
    }

    private var sizePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                field("Ancho", value: store.resize.width) { store.widthChanged($0) }

                Button {
                    store.lockAspect.toggle()
                } label: {
                    Image(systemName: store.lockAspect ? "lock.fill" : "lock.open")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(store.lockAspect
                                    ? "Proporción bloqueada"
                                    : "Proporción libre")

                field("Alto", value: store.resize.height) { store.heightChanged($0) }
            }

            Picker("Encaje", selection: $store.resize.fit) {
                ForEach(Resizer.Fit.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(store.resize.fit.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.resize.fit == .contain {
                Toggle("Margen blanco", isOn: $store.resize.opaqueMargin)
            }

            Text("Medidas frecuentes").font(.subheadline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Resizer.presets) { p in
                        Button(p.name) { store.commit(); store.applyPreset(p) }
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
            }
            .scrollClipDisabled()

            HStack {
                LabeledContent("Recorte", value: store.croppedSize)
                Spacer()
                if store.sizeTouched {
                    Button("Nativo") { store.useNativeSize() }
                        .font(.footnote.weight(.semibold))
                }
            }
            .font(.footnote)

            if let note = store.resampleNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Formato de salida").font(.subheadline)
            Picker("Formato", selection: $store.export.format) {
                ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(store.export.format.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.export.format == .jpeg {
                labeled("Calidad", String(format: "%.0f%%", store.export.quality * 100)) {
                    Slider(value: $store.export.quality, in: 0.3...1)
                }
            }

            if store.export.format == .pdf {
                labeled("Resolución", String(format: "%.0f ppp", store.export.dpi)) {
                    Slider(value: $store.export.dpi, in: 72...300, step: 1)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Piezas

    private func field(_ title: String, value: Int,
                       onChange: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: Binding(
                get: { value },
                set: { onChange($0) }
            ), format: .number)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 36)
        }
    }

    private func group<C: View>(_ title: String,
                                @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, _ format: String) -> some View {
        labeled(title, String(format: format, value.wrappedValue)) {
            Slider(value: value, in: range) { editing in
                // Al empezar a arrastrar, no en cada fotograma: así deshacer
                // retrocede un ajuste entero y no un píxel de recorrido.
                if editing { store.commit() }
            }
        }
    }

    private func labeled<C: View>(_ title: String, _ readout: String,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(readout)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }
}
