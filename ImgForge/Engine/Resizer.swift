import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Redimensionado a medidas exactas, como el Tamaño de imagen de Photoshop.
enum Resizer {

    /// Qué hacer cuando la proporción pedida no coincide con la original.
    enum Fit: String, CaseIterable, Identifiable, Hashable {
        /// Deforma la imagen hasta llenar exactamente el destino.
        case stretch = "Estirar"
        /// Encaja entera y deja margen. Nada se recorta.
        case contain = "Contener"
        /// Llena el destino y recorta lo que sobra, centrado.
        case cover = "Cubrir"

        var id: String { rawValue }

        var detail: String {
            switch self {
            case .stretch: return "Deforma para llenar la medida exacta"
            case .contain: return "Entra completa, con margen alrededor"
            case .cover:   return "Llena el marco y recorta los bordes"
            }
        }
    }

    struct Options: Hashable {
        var width: Int = 0
        var height: Int = 0
        var fit: Fit = .cover
        var method: Upscaler.Method = .lanczos
        /// Margen opaco en blanco para `contain`; si no, transparente.
        var opaqueMargin: Bool = false
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func run(_ input: UIImage,
                    options: Options,
                    isCancelled: () -> Bool = { false }) throws -> UIImage {
        guard let cg = input.cgImage else { throw ForgeError.decodeFailed }

        let target = CGSize(width: max(1, options.width), height: max(1, options.height))
        guard Int(target.width) * Int(target.height) <= ForgeEnvironment.maxOutputPixels else {
            throw ForgeError.tooLarge(pixels: Int(target.width) * Int(target.height),
                                      limit: ForgeEnvironment.maxOutputPixels)
        }
        if isCancelled() { throw ForgeError.cancelled }

        let source = CGSize(width: cg.width, height: cg.height)
        let sx = target.width / source.width
        let sy = target.height / source.height

        // Una sola pasada de remuestreo: escalar dos veces emborrona.
        let factor: CGFloat
        switch options.fit {
        case .stretch: factor = 0          // se trata aparte
        case .contain: factor = min(sx, sy)
        case .cover:   factor = max(sx, sy)
        }

        let scaled: CGImage
        if options.fit == .stretch {
            scaled = try resample(cg, to: target, method: options.method)
        } else {
            let size = CGSize(width: (source.width * factor).rounded(),
                              height: (source.height * factor).rounded())
            scaled = try resample(cg, to: size, method: options.method)
        }

        if isCancelled() { throw ForgeError.cancelled }

        // Si ya mide lo pedido, no hay lienzo que componer.
        if scaled.width == Int(target.width) && scaled.height == Int(target.height) {
            return UIImage(cgImage: scaled)
        }

        let opaque = options.fit == .contain && options.opaqueMargin
        guard let canvas = CGContext(
            data: nil,
            width: Int(target.width), height: Int(target.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast
                                : CGImageAlphaInfo.premultipliedLast).rawValue
        ) else { throw ForgeError.renderFailed }

        if opaque {
            canvas.setFillColor(UIColor.white.cgColor)
            canvas.fill(CGRect(origin: .zero, size: target))
        }

        // Centrado: lo que sobra se recorta por igual a ambos lados.
        let rect = CGRect(
            x: (target.width - CGFloat(scaled.width)) / 2,
            y: (target.height - CGFloat(scaled.height)) / 2,
            width: CGFloat(scaled.width),
            height: CGFloat(scaled.height)
        )
        canvas.interpolationQuality = .high
        canvas.draw(scaled, in: rect)

        guard let out = canvas.makeImage() else { throw ForgeError.renderFailed }
        return UIImage(cgImage: out)
    }

    private static func resample(_ cg: CGImage,
                                 to size: CGSize,
                                 method: Upscaler.Method) throws -> CGImage {
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))
        if w == cg.width && h == cg.height { return cg }

        var image = CIImage(cgImage: cg)
        let sx = CGFloat(w) / CGFloat(cg.width)
        let sy = CGFloat(h) / CGFloat(cg.height)

        switch method {
        case .nearest:
            image = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                         .samplingNearest()
        default:
            // Lanczos y bicúbico toman una escala y una relación de aspecto:
            // la deformación va en aspectRatio, no en una segunda pasada.
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = image
            f.scale = Float(sy)
            f.aspectRatio = Float(sx / sy)
            guard let out = f.outputImage else {
                throw ForgeError.filterFailed("lanczosScaleTransform")
            }
            image = out
        }

        guard let out = context.createCGImage(
            image, from: CGRect(x: 0, y: 0, width: w, height: h)
        ) else { throw ForgeError.renderFailed }
        return out
    }

    // MARK: - Medidas frecuentes

    struct SizePreset: Identifiable, Hashable {
        let name: String
        let width: Int
        let height: Int
        var id: String { "\(name)-\(width)x\(height)" }
    }

    static let presets: [SizePreset] = [
        SizePreset(name: "Cuadrado 1080", width: 1080, height: 1080),
        SizePreset(name: "Vertical 1080×1350", width: 1080, height: 1350),
        SizePreset(name: "Historia 1080×1920", width: 1080, height: 1920),
        SizePreset(name: "HD 1920×1080", width: 1920, height: 1080),
        SizePreset(name: "4K 3840×2160", width: 3840, height: 2160),
        SizePreset(name: "Portada 1200×628", width: 1200, height: 628),
        SizePreset(name: "A4 300 ppp", width: 2480, height: 3508)
    ]
}
