import SwiftUI
import Observation

/// Bandera compartida con el trabajo en segundo plano.
/// `Task.isCancelled` no llega al interior de un bucle síncrono.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }
}

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

    var upscaleOptions = Upscaler.Options() {
        didSet { scheduleDraft(); persist() }
    }
    var vectorOptions = Vectorizer.Options() { didSet { persist() } }

    /// `ColorMode` no se edita bien desde un control; se expone en dos piezas.
    var vectorInColor: Bool {
        get { if case .palette = vectorOptions.colorMode { return true }; return false }
        set { vectorOptions.colorMode = newValue ? .palette(paletteCount) : .mono }
    }

    var paletteCount: Int = 8 {
        didSet {
            if vectorInColor { vectorOptions.colorMode = .palette(paletteCount) }
        }
    }

    private(set) var isRendering = false
    private(set) var isDrafting = false
    var error: String?
    var status: String?

    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var token = CancelToken()

    init() {
        restore()
    }

    // MARK: - Persistencia

    private enum Key {
        static let scale = "forge.scale"
        static let method = "forge.method"
        static let sharpen = "forge.sharpen"
        static let noise = "forge.noise"
        static let engine = "forge.engine"
        static let mode = "forge.mode"
        static let curves = "forge.curves"
        static let simplify = "forge.simplify"
        static let color = "forge.color"
        static let palette = "forge.palette"
    }

    private var restoring = false

    private func persist() {
        guard !restoring else { return }
        let d = UserDefaults.standard
        d.set(Double(upscaleOptions.scale), forKey: Key.scale)
        d.set(upscaleOptions.method.rawValue, forKey: Key.method)
        d.set(Double(upscaleOptions.sharpen), forKey: Key.sharpen)
        d.set(upscaleOptions.noiseReduction, forKey: Key.noise)
        d.set(upscaleOptions.engine.rawValue, forKey: Key.engine)
        d.set(mode.rawValue, forKey: Key.mode)
        d.set(vectorOptions.curves, forKey: Key.curves)
        d.set(Double(vectorOptions.simplify), forKey: Key.simplify)
        d.set(vectorInColor, forKey: Key.color)
        d.set(paletteCount, forKey: Key.palette)
    }

    private func restore() {
        let d = UserDefaults.standard
        guard d.object(forKey: Key.scale) != nil else { return }
        restoring = true
        defer { restoring = false }

        upscaleOptions.scale = CGFloat(d.double(forKey: Key.scale))
        if let m = Upscaler.Method(rawValue: d.string(forKey: Key.method) ?? "") {
            upscaleOptions.method = m
        }
        upscaleOptions.sharpen = Float(d.double(forKey: Key.sharpen))
        upscaleOptions.noiseReduction = d.bool(forKey: Key.noise)
        if let e = Upscaler.Engine(rawValue: d.string(forKey: Key.engine) ?? "") {
            upscaleOptions.engine = e
        }
        if let m = Mode(rawValue: d.string(forKey: Key.mode) ?? "") {
            mode = m
        }
        vectorOptions.curves = d.bool(forKey: Key.curves)
        let simplify = Float(d.double(forKey: Key.simplify))
        if simplify > 0 { vectorOptions.simplify = simplify }
        paletteCount = max(2, min(16, d.integer(forKey: Key.palette)))
        vectorOptions.colorMode = d.bool(forKey: Key.color) ? .palette(paletteCount) : .mono
    }

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
        token.cancel()
        token = CancelToken()
        isRendering = true
        error = nil
        status = nil

        let mode = self.mode
        let up = upscaleOptions
        let vec = vectorOptions
        let token = self.token

        renderTask = Task { [weak self] in
            let outcome: Result<(UIImage?, Vectorizer.Result?), Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        switch mode {
                        case .upscale:
                            let image = try Upscaler.run(
                                src, options: up,
                                isCancelled: { token.isCancelled })
                            return .success((image, nil))
                        case .vector:
                            let vector = try Vectorizer.run(
                                src, options: vec,
                                isCancelled: { token.isCancelled })
                            return .success((nil, vector))
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
                if case ForgeError.cancelled = e {
                    self.status = "Cancelado."
                } else {
                    self.error = e.localizedDescription
                }
            }
            self.isRendering = false
        }
    }

    func cancel() {
        token.cancel()
        renderTask?.cancel()
        isRendering = false
        status = "Cancelado."
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
