import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var store = ForgeStore()
    @State private var pick: PhotosPickerItem?
    @State private var shareURL: URL?
    @State private var saving = false
    @State private var fullscreen = false
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A tamaños accesibles los controles se apilan en vez de comprimirse.
    private var stacked: Bool { typeSize >= .accessibility1 }

    var body: some View {
        TabView {
            forge
                .tabItem { Label("Forja", systemImage: "wand.and.rays") }
            EditorView()
                .tabItem { Label("Editor", systemImage: "slider.horizontal.below.rectangle") }
            BatchView()
                .tabItem { Label("Lote", systemImage: "square.stack.3d.up") }
        }
    }

    private var forge: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ZoomableImageView(
                        before: store.source,
                        after: store.preview ?? store.result,
                        splitEnabled: $store.splitEnabled
                    )
                    .frame(height: stacked ? 240 : 300)
                    .padding(.horizontal, 16)
                    .overlay(alignment: .topTrailing) {
                        if store.isDrafting {
                            ProgressView()
                                .controlSize(.small)
                                .padding(20)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if store.source != nil {
                            Button {
                                fullscreen = true
                            } label: {
                                Label("Pantalla completa", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption.weight(.semibold))
                                    .labelStyle(.iconOnly)
                                    .frame(width: 36, height: 36)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .padding(26)
                            .accessibilityLabel("Ver a pantalla completa")
                        }
                    }

                    if store.source != nil {
                        Toggle("Comparar antes y después", isOn: $store.splitEnabled)
                            .padding(.horizontal, 16)

                        PresetBar(presets: Preset.all) { store.apply($0) }

                        Picker("Modo", selection: $store.mode) {
                            ForEach(ForgeStore.Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)

                        controls
                    } else {
                        placeholder
                    }

                    footer
                }
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("ImgForge")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(selection: $pick, matching: .images) {
                        Label("Cargar", systemImage: "photo.badge.plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        do { shareURL = try store.exportURL() }
                        catch { store.error = error.localizedDescription }
                    } label: {
                        Label("Exportar", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.result == nil && store.svg == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        saveToPhotos()
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Label("Guardar en Fotos", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(store.result == nil || saving
                              || !store.export.format.savesToPhotos)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if store.source != nil {
                    Button(store.isRendering ? "Cancelar" : actionTitle) {
                        if store.isRendering { store.cancel() } else { store.render() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(.bar)
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
            .sheet(item: Binding(
                get: { shareURL.map(SharedURL.init) },
                set: { shareURL = $0?.url }
            )) { item in
                ShareSheet(urls: [item.url])
            }
            .fullScreenCover(isPresented: $fullscreen) {
                FullscreenPreview(
                    before: store.source,
                    after: store.preview ?? store.result,
                    splitEnabled: $store.splitEnabled
                )
            }
        }
    }

    private func saveToPhotos() {
        saving = true
        Task {
            do {
                let url = try store.exportURL()
                let outcome = await PhotoSaver.save(urls: [url])
                store.status = outcome.message
            } catch {
                store.error = error.localizedDescription
            }
            saving = false
        }
    }

    private var actionTitle: String {
        store.mode == .upscale ? "Ampliar" : "Vectorizar"
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("Ninguna imagen", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Carga un PNG o JPG para ampliarlo o convertirlo en vector.")
        } actions: {
            PhotosPicker(selection: $pick, matching: .images) {
                Label("Elegir de Fotos", systemImage: "photo.badge.plus")
                    .frame(maxWidth: 260, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let e = store.error {
            Label(e, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        } else if let s = store.status {
            Text(s)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 16) {
            if store.mode == .upscale {
                slider("Escala",
                       value: $store.upscaleOptions.scale.asDouble,
                       range: 1...max(1.5, store.maxScale), step: 0.5,
                       readout: String(format: "%.1f×", store.upscaleOptions.scale))

                Picker("Motor", selection: $store.upscaleOptions.engine) {
                    ForEach(Upscaler.Engine.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                slider("Nitidez",
                       value: $store.upscaleOptions.sharpen.asDouble,
                       range: 0...2, step: 0.05,
                       readout: String(format: "%.2f", store.upscaleOptions.sharpen))

                Toggle("Reducción de ruido", isOn: $store.upscaleOptions.noiseReduction)

                LabeledContent("Salida", value: store.outputSize)
                    .font(.footnote)

                Divider()

                Picker("Formato", selection: $store.export.format) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if store.export.format == .jpeg {
                    slider("Calidad",
                           value: $store.export.quality,
                           range: 0.3...1, step: 0.05,
                           readout: String(format: "%.0f%%", store.export.quality * 100))
                }

                if store.export.format == .pdf {
                    slider("Resolución",
                           value: $store.export.dpi,
                           range: 72...300, step: 1,
                           readout: String(format: "%.0f ppp", store.export.dpi))
                }
            } else {
                Toggle("Vectorizar a color", isOn: $store.vectorInColor)

                if !store.vectorInColor {
                    Toggle("Umbral automático", isOn: Binding(
                        get: { store.vectorOptions.threshold == nil },
                        set: { store.vectorOptions.threshold = $0 ? nil : 128 }))

                    if let current = store.vectorOptions.threshold {
                        slider("Umbral",
                               value: Binding(
                                   get: { Double(current) },
                                   set: { store.vectorOptions.threshold = Int($0) }),
                               range: 1...255, step: 1,
                               readout: "\(current)")
                    }
                }

                if store.vectorInColor {
                    slider("Colores",
                           value: Binding(
                               get: { Double(store.paletteCount) },
                               set: { store.paletteCount = Int($0) }),
                           range: 2...16, step: 1,
                           readout: "\(store.paletteCount)")
                }

                Toggle("Curvas Bézier", isOn: $store.vectorOptions.curves)

                if store.vectorOptions.curves {
                    slider("Esquinas",
                           value: $store.vectorOptions.cornerAngle.asDouble,
                           range: 20...140, step: 5,
                           readout: "\(Int(store.vectorOptions.cornerAngle))°")
                }
                Toggle("Invertir", isOn: $store.vectorOptions.invert)
                Toggle("Solo contorno", isOn: $store.vectorOptions.strokeOnly)

                slider("Simplificar",
                       value: $store.vectorOptions.simplify.asDouble,
                       range: 0.0005...0.02, step: 0.0005,
                       readout: String(format: "%.4f", store.vectorOptions.simplify))
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
    }

    /// A tamaños accesibles la etiqueta y el valor se apilan sobre el slider.
    @ViewBuilder
    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        step: Double,
                        readout: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if stacked {
                Text(title)
                Text(readout)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(title)
                    Spacer()
                    Text(readout)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Slider(value: value, in: range, step: step) { Text(title) }
                .accessibilityValue(readout)
        }
    }
}
