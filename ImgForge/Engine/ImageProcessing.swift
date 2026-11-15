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

    static func process(_ image: UIImage,
                        preset: Preset,
                        stem: String? = nil,
                        export: Exporter.Settings = Exporter.Settings()) throws -> URL {
        let name = stem ?? "imgforge_\(Int(Date().timeIntervalSince1970))"

        switch preset.kind {
        case .upscale(let opts):
            let out = try Upscaler.run(image, options: opts)
            return try Exporter.write(out, settings: export,
                                      stem: "\(name)_x\(Int(opts.scale))")

        case .vector(let opts):
            let result = try Vectorizer.run(image, options: opts)
            return try Exporter.writeSVG(result.svg, stem: name)
        }
    }
}
