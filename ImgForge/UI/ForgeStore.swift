import SwiftUI
import Observation

@Observable
@MainActor
final class ForgeStore {

    enum Mode: String, CaseIterable, Identifiable {
        case upscale = "Upscale"
        case vector = "Vector"
        var id: String { rawValue }
    }

    var mode: Mode = .upscale
    var source: UIImage?
    var preview: UIImage?
    var result: UIImage?
    var svg: Vectorizer.Result?
    var splitEnabled = true

    var upscaleOptions = Upscaler.Options() { didSet { scheduleDraft() } }
    var vectorOptions = Vectorizer.Options()

    private(set) var isRendering = false
    private(set) var isDrafting = false
    var error: String?
    var status: String?

    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?

    // MARK: - Derivados

    var sourceSize: String {
        guard let cg = source?.cgImage else { return "—" }
        return "\(cg.width) × \(cg.height)"
    }

    var outputSize: String {
        guard let cg = source?.cgImage else { return "—" }
        let s = upscaleOptions.scale
        return "\(Int(CGFloat(cg.width) * s)) × \(Int(CGFloat(cg.height) * s))"
    }

    var engineLabel: String {
        switch upscaleOptions.engine {
        case .neural:
            return NeuralUpscaler.isAvailable ? "Neural Engine" : "Modelo ausente"
        case .classic:
            return "Core Image"
        case .auto:
            return NeuralUpscaler.isAvailable ? "Auto · Neural" : "Auto · Clásico"
        }
    }

    // MARK: - Ciclo

    func load(_ image: UIImage) {
        source = image.normalizedOrientation()
        preview = nil
        result = nil
        svg = nil
        error = nil
        status = nil
        scheduleDraft()
    }

    func reset() {
        draftTask?.cancel()
        renderTask?.cancel()
        source = nil
        preview = nil
        result = nil
        svg = nil
        error = nil
        status = nil
    }

    func apply(_ preset: Preset) {
        switch preset.kind {
        case .upscale(let o):
            mode = .upscale
            upscaleOptions = o
        case .vector(let o):
            mode = .vector
            vectorOptions = o
        }
        status = preset.name
    }

    // MARK: - Draft con debounce

    /// Cada cambio de slider cancela el draft anterior y agenda uno nuevo tras 120 ms.
    func scheduleDraft() {
        guard let src = source, mode == .upscale else { return }
        draftTask?.cancel()
        isDrafting = true

        let opts = upscaleOptions
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }

            let out = await Task.detached(priority: .userInitiated) {
                try? Upscaler.run(src, options: opts, quality: .draft(maxEdge: 900))
            }.value

            guard !Task.isCancelled, let self else { return }
            if let out { self.preview = out }
            self.isDrafting = false
        }
    }

    // MARK: - Render completo

    func render() {
        guard let src = source else {
            error = ForgeError.noImage.localizedDescription
            return
        }
        renderTask?.cancel()
        isRendering = true
        error = nil
        status = nil

        let mode = self.mode
        let up = upscaleOptions
        let vec = vectorOptions

        renderTask = Task { [weak self] in
            let outcome: Result<(UIImage?, Vectorizer.Result?), Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        switch mode {
                        case .upscale:
                            return .success((try Upscaler.run(src, options: up), nil))
                        case .vector:
                            return .success((nil, try Vectorizer.run(src, options: vec)))
                        }
                    } catch {
                        return .failure(error)
                    }
                }.value

            guard !Task.isCancelled, let self else { return }

            switch outcome {
            case .success(let (image, vector)):
                if let image {
                    self.result = image
                    self.preview = image
                    self.status = "\(self.outputSize) · \(self.engineLabel)"
                }
                if let vector {
                    self.svg = vector
                    self.status = "\(vector.pathCount) trazos · \(vector.byteCount / 1024) KB"
                }
            case .failure(let e):
                self.error = e.localizedDescription
            }
            self.isRendering = false
        }
    }

    func cancel() {
        renderTask?.cancel()
        isRendering = false
    }

    // MARK: - Export

    func exportURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let stamp = Int(Date().timeIntervalSince1970)

        if let svg {
            let url = dir.appendingPathComponent("imgforge_\(stamp).svg")
            do { try svg.svg.write(to: url, atomically: true, encoding: .utf8) }
            catch { throw ForgeError.writeFailed(error.localizedDescription) }
            return url
        }

        guard let result else { throw ForgeError.noImage }
        guard let data = result.pngData() else { throw ForgeError.encodeFailed }
        let url = dir.appendingPathComponent("imgforge_\(stamp).png")
        do { try data.write(to: url, options: .atomic) }
        catch { throw ForgeError.writeFailed(error.localizedDescription) }
        return url
    }
}
