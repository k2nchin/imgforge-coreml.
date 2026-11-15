import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Ajustes de imagen, en el orden en que Photoshop los aplicaría:
/// geometría primero, luego tono, luego color, y la nitidez al final.
enum Adjustments {

    struct Options: Hashable {
        // Geometría
        var rotationQuarters: Int = 0      // 0–3, giros de 90°
        var flipHorizontal: Bool = false
        var flipVertical: Bool = false
        var straighten: Double = 0         // −15…15 grados

        // Tono
        var exposure: Double = 0           // −2…2 pasos
        var contrast: Double = 1           // 0.5…1.5
        var highlights: Double = 1         // 0…1
        var shadows: Double = 0            // −1…1
        var blackPoint: Double = 0         // 0…0.2

        // Color
        var saturation: Double = 1         // 0…2
        var temperature: Double = 6500     // 3000…9000 K
        var tint: Double = 0               // −100…100
        var vibrance: Double = 0           // −1…1

        // Detalle
        var sharpness: Double = 0          // 0…2
        var noiseReduction: Double = 0     // 0…0.1

        var isIdentity: Bool { self == Options() }

        /// Cuántos ajustes se apartan del valor neutro. Sirve para el badge.
        var activeCount: Int {
            var n = 0
            if rotationQuarters != 0 { n += 1 }
            if flipHorizontal || flipVertical { n += 1 }
            if straighten != 0 { n += 1 }
            if exposure != 0 { n += 1 }
            if contrast != 1 { n += 1 }
            if highlights != 1 || shadows != 0 { n += 1 }
            if blackPoint != 0 { n += 1 }
            if saturation != 1 { n += 1 }
            if temperature != 6500 || tint != 0 { n += 1 }
            if vibrance != 0 { n += 1 }
            if sharpness != 0 { n += 1 }
            if noiseReduction != 0 { n += 1 }
            return n
        }
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// - Parameter crop: recorte en coordenadas normalizadas (0–1), origen
    ///   arriba-izquierda. `nil` es la imagen entera.
    static func apply(_ input: UIImage,
                      options: Options,
                      crop: CGRect? = nil,
                      maxEdge: Int? = nil,
                      isCancelled: () -> Bool = { false }) throws -> UIImage {
        guard let cg = input.cgImage else { throw ForgeError.decodeFailed }

        var image = CIImage(cgImage: cg)

        // 1. Recorte, antes de todo: lo demás trabaja sobre menos píxeles.
        if let crop, crop != CGRect(x: 0, y: 0, width: 1, height: 1) {
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            // CIImage tiene el origen abajo; el recorte llega con origen arriba.
            let rect = CGRect(x: crop.minX * w,
                              y: (1 - crop.maxY) * h,
                              width: crop.width * w,
                              height: crop.height * h).integral
            guard rect.width >= 1, rect.height >= 1 else { throw ForgeError.decodeFailed }
            image = image.cropped(to: rect)
            image = image.transformed(by: CGAffineTransform(translationX: -rect.minX,
                                                            y: -rect.minY))
        }

        if isCancelled() { throw ForgeError.cancelled }

        // 2. Vista previa a tamaño reducido, si se pide.
        if let maxEdge {
            let longest = max(image.extent.width, image.extent.height)
            if longest > CGFloat(maxEdge) {
                let f = CIFilter.lanczosScaleTransform()
                f.inputImage = image
                f.scale = Float(CGFloat(maxEdge) / longest)
                f.aspectRatio = 1
                if let out = f.outputImage { image = out }
            }
        }

        // 3. Geometría.
        image = geometry(image, options: options)

        if isCancelled() { throw ForgeError.cancelled }

        // 4. Tono, color y detalle.
        image = try tone(image, options: options)
        image = try color(image, options: options)
        image = try detail(image, options: options)

        let extent = image.extent.integral
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1,
              let out = context.createCGImage(image, from: extent) else {
            throw ForgeError.renderFailed
        }
        return UIImage(cgImage: out)
    }

    // MARK: - Geometría

    private static func geometry(_ input: CIImage, options: Options) -> CIImage {
        var image = input

        if options.flipHorizontal || options.flipVertical {
            let e = image.extent
            var t = CGAffineTransform.identity
            if options.flipHorizontal {
                t = t.translatedBy(x: e.width, y: 0).scaledBy(x: -1, y: 1)
            }
            if options.flipVertical {
                t = t.translatedBy(x: 0, y: e.height).scaledBy(x: 1, y: -1)
            }
            image = image.transformed(by: t)
        }

        let quarters = ((options.rotationQuarters % 4) + 4) % 4
        if quarters != 0 {
            let angle = -CGFloat(quarters) * .pi / 2
            image = image.transformed(by: CGAffineTransform(rotationAngle: angle))
        }

        if options.straighten != 0 {
            let angle = -CGFloat(options.straighten) * .pi / 180
            let before = image.extent
            image = image.transformed(by: CGAffineTransform(rotationAngle: angle))
            // Se recorta al rectángulo original centrado: girar deja esquinas
            // vacías, y una franja transparente en el borde no es un ajuste.
            let after = image.extent
            let inset = CGRect(
                x: after.midX - before.width / 2 * cos(abs(angle)),
                y: after.midY - before.height / 2 * cos(abs(angle)),
                width: before.width * cos(abs(angle)),
                height: before.height * cos(abs(angle))
            )
            image = image.cropped(to: inset.intersection(after))
        }

        return image
    }

    // MARK: - Tono

    private static func tone(_ input: CIImage, options: Options) throws -> CIImage {
        var image = input

        if options.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(options.exposure)
            guard let o = f.outputImage else { throw ForgeError.filterFailed("exposure") }
            image = o
        }

        if options.highlights != 1 || options.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.highlightAmount = Float(options.highlights)
            f.shadowAmount = Float(options.shadows)
            guard let o = f.outputImage else { throw ForgeError.filterFailed("highlights") }
            image = o
        }

        if options.contrast != 1 || options.blackPoint != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.contrast = Float(options.contrast)
            f.brightness = Float(-options.blackPoint)
            f.saturation = 1
            guard let o = f.outputImage else { throw ForgeError.filterFailed("contrast") }
            image = o
        }

        return image
    }

    // MARK: - Color

    private static func color(_ input: CIImage, options: Options) throws -> CIImage {
        var image = input

        if options.temperature != 6500 || options.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: CGFloat(options.temperature), y: CGFloat(options.tint))
            f.targetNeutral = CIVector(x: 6500, y: 0)
            guard let o = f.outputImage else { throw ForgeError.filterFailed("temperature") }
            image = o
        }

        if options.saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.saturation = Float(options.saturation)
            f.contrast = 1
            f.brightness = 0
            guard let o = f.outputImage else { throw ForgeError.filterFailed("saturation") }
            image = o
        }

        if options.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = image
            f.amount = Float(options.vibrance)
            guard let o = f.outputImage else { throw ForgeError.filterFailed("vibrance") }
            image = o
        }

        return image
    }

    // MARK: - Detalle

    private static func detail(_ input: CIImage, options: Options) throws -> CIImage {
        var image = input

        if options.noiseReduction > 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = image
            f.noiseLevel = Float(options.noiseReduction)
            f.sharpness = 0.4
            guard let o = f.outputImage else { throw ForgeError.filterFailed("noise") }
            image = o
        }

        if options.sharpness > 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = image
            f.radius = 2.0
            f.intensity = Float(options.sharpness)
            guard let o = f.outputImage else { throw ForgeError.filterFailed("sharpen") }
            image = o
        }

        return image
    }
}
