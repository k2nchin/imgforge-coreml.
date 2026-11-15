import UIKit
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await loadImage() }
    }

    private func loadImage() async {
        guard let item = (extensionContext?.inputItems as? [NSExtensionItem])?.first,
              let provider = item.attachments?.first(where: {
                  $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
              }) else {
            return finish(error: "No se encontró ninguna imagen.")
        }

        do {
            let loaded = try await provider.loadItem(
                forTypeIdentifier: UTType.image.identifier, options: nil)

            let image: UIImage?
            switch loaded {
            case let url as URL:     image = UIImage(contentsOfFile: url.path)
            case let data as Data:   image = UIImage(data: data)
            case let img as UIImage: image = img
            default:                 image = nil
            }

            guard let image else { return finish(error: "Formato no soportado.") }
            present(image.normalizedOrientation())
        } catch {
            finish(error: error.localizedDescription)
        }
    }

    private func present(_ image: UIImage) {
        let root = SharePanel(
            image: image,
            onDone: { [weak self] in self?.complete() },
            onCancel: { [weak self] in self?.complete() }
        )
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func finish(error: String) {
        let alert = UIAlertController(title: "ImgForge",
                                      message: error,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.extensionContext?.cancelRequest(
                withError: NSError(domain: "ImgForge", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: error]))
        })
        present(alert, animated: true)
    }
}

struct SharePanel: View {
    let image: UIImage
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var preset: Preset = Preset.all[0]
    @State private var working = false
    @State private var output: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Picker("Preset", selection: $preset) {
                    ForEach(Preset.all) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
                .frame(maxHeight: 200)

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Spacer()

                Button(working ? "Procesando…" : "Procesar y guardar") { run() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(working)
            }
            .padding(20)
            .navigationTitle("ImgForge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", action: onCancel)
                }
            }
            .sheet(item: Binding(
                get: { output.map(SharedOutput.init) },
                set: { output = $0?.url }
            )) { item in
                ActivityView(url: item.url, onDismiss: onDone)
            }
        }
    }

    private func run() {
        working = true
        error = nil
        let img = image
        let p = preset

        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try ForgeRunner.process(img, preset: p)
                }.value
                await MainActor.run {
                    output = url
                    working = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    working = false
                }
            }
        }
    }
}

private struct SharedOutput: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onDismiss() }
        return vc
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
