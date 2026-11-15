import UIKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Hashable {
    case png = "PNG"
    case jpeg = "JPG"
    case pdf = "PDF"

    var id: String { rawValue }

    var ext: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .pdf: return "pdf"
        }
    }

    var detail: String {
        switch self {
        case .png:  return "Sin pérdida, admite transparencia"
        case .jpeg: return "Más liviano, sin transparencia"
        case .pdf:  return "Documento, para imprimir o enviar"
        }
    }

    /// Fotos sí, carrete: un PDF no es un asset válido.
    var savesToPhotos: Bool { self != .pdf }
}

enum Exporter {

    struct Settings: Hashable {
        var format: ExportFormat = .png
        /// Calidad JPEG, 0.3–1.0.
        var quality: Double = 0.9
        /// Puntos por pulgada del PDF. 72 deja la página del tamaño en píxeles.
        var dpi: Double = 72
    }

    static func write(_ image: UIImage,
                      settings: Settings,
                      stem: String? = nil,
                      directory: URL? = nil) throws -> URL {
        let dir = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("imgforge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let name = stem ?? "imgforge_\(Int(Date().timeIntervalSince1970))"
        let url = dir.appendingPathComponent("\(name).\(settings.format.ext)")

        let data: Data
        switch settings.format {
        case .png:
            guard let d = image.pngData() else { throw ForgeError.encodeFailed }
            data = d

        case .jpeg:
            // JPEG no tiene alfa: lo transparente se compone sobre blanco
            // en vez de salir negro, que es lo que hace una conversión cruda.
            let flat = flatten(image)
            guard let d = flat.jpegData(compressionQuality: min(1, max(0.3, settings.quality))) else {
                throw ForgeError.encodeFailed
            }
            data = d

        case .pdf:
            data = try pdf(image, dpi: settings.dpi)
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ForgeError.writeFailed(error.localizedDescription)
        }
        return url
    }

    /// Escribe el SVG tal cual; el formato de imagen no aplica a un vector.
    static func writeSVG(_ svg: String, stem: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imgforge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let name = stem ?? "imgforge_\(Int(Date().timeIntervalSince1970))"
        let url = dir.appendingPathComponent("\(name).svg")
        do {
            try svg.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ForgeError.writeFailed(error.localizedDescription)
        }
        return url
    }

    // MARK: - Interna

    private static func flatten(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let size = CGSize(width: cg.width, height: cg.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func pdf(_ image: UIImage, dpi: Double) throws -> Data {
        guard let cg = image.cgImage else { throw ForgeError.encodeFailed }

        // Un punto PDF es 1/72 de pulgada: a 300 ppp la página mide menos
        // puntos que píxeles, y la imagen sale impresa a su resolución real.
        let scale = 72.0 / max(36, dpi)
        let size = CGSize(width: CGFloat(cg.width) * scale,
                          height: CGFloat(cg.height) * scale)
        guard size.width >= 1, size.height >= 1 else { throw ForgeError.encodeFailed }

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        return renderer.pdfData { ctx in
            ctx.beginPage()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
