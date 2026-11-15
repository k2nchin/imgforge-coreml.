import SwiftUI
import PhotosUI

struct BatchView: View {
    @State private var queue = BatchQueue()
    @State private var picks: [PhotosPickerItem] = []
    @State private var preset: Preset = Preset.all[0]
    @State private var shareURLs: [URL] = []
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            Group {
                if queue.jobs.isEmpty { empty } else { list }
            }
            .navigationTitle("Lote")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(selection: $picks, maxSelectionCount: 50, matching: .images) {
                        Label("Añadir", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Vaciar") { queue.clear() }
                        .disabled(queue.jobs.isEmpty || queue.isRunning)
                }
            }
            .safeAreaInset(edge: .bottom) { controls }
            .onChange(of: picks) { _, items in
                guard !items.isEmpty else { return }
                Task { await ingest(items) }
            }
            .sheet(isPresented: $showShare) { ShareSheet(urls: shareURLs) }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Cola vacía", systemImage: "square.stack.3d.up")
        } description: {
            Text("Añade imágenes para procesarlas todas con el mismo preset.")
        } actions: {
            PhotosPicker(selection: $picks, maxSelectionCount: 50, matching: .images) {
                Label("Elegir de Fotos", systemImage: "photo.badge.plus")
                    .frame(maxWidth: 260, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(queue.jobs) { job in
                    HStack(spacing: 12) {
                        Image(uiImage: job.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.name).lineLimit(1)
                            if let m = job.message {
                                Text(m)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        icon(for: job.state)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text(queue.summary)
            }
        }
    }

    @ViewBuilder
    private func icon(for state: BatchQueue.Job.State) -> some View {
        switch state {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView()
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if queue.isRunning {
                ProgressView(value: queue.progress)
                    .tint(Color.accentColor)
            }

            Picker("Preset", selection: $preset) {
                ForEach(Preset.all) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button(queue.isRunning ? "Detener" : "Procesar") {
                    if queue.isRunning {
                        queue.cancel()
                    } else {
                        queue.start(preset: preset)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(queue.jobs.isEmpty)

                Button {
                    shareURLs = queue.outputs
                    showShare = !shareURLs.isEmpty
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .frame(height: 30)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(queue.outputs.isEmpty)
                .accessibilityLabel("Exportar resultados")
            }
        }
        .padding(16)
        .background(.bar)
    }

    private func ingest(_ items: [PhotosPickerItem]) async {
        var loaded: [(String, UIImage)] = []
        for (i, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data) else { continue }
            loaded.append(("imagen_\(i + 1)", img.normalizedOrientation()))
        }
        queue.enqueue(loaded)
        picks.removeAll()
    }
}
