import UIKit

extension UIImage {
    /// Hornea la orientación EXIF para que Core Image y Vision no trabajen rotados.
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Procesa una imagen con un preset y escribe el resultado en temporales.
/// Compartido por la app, la cola de lote y la Share Extension.
enum ForgeRunner {

    static func process(_ image: UIImage, preset: Preset, stem: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imgforge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let name = stem ?? "imgforge_\(Int(Date().timeIntervalSince1970))"

        switch preset.kind {
        case .upscale(let opts):
            let out = try Upscaler.run(image, options: opts)
            guard let data = out.pngData() else { throw ForgeError.encodeFailed }
            let url = dir.appendingPathComponent("\(name)_x\(Int(opts.scale)).png")
            do { try data.write(to: url, options: .atomic) }
            catch { throw ForgeError.writeFailed(error.localizedDescription) }
            return url

        case .vector(let opts):
            let result = try Vectorizer.run(image, options: opts)
            let url = dir.appendingPathComponent("\(name).svg")
            do { try result.svg.write(to: url, atomically: true, encoding: .utf8) }
            catch { throw ForgeError.writeFailed(error.localizedDescription) }
            return url
        }
    }
}
