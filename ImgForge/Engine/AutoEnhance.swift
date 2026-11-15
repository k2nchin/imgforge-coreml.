import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Mide la imagen y propone ajustes, como el Tono automático de Photoshop.
/// No inventa: parte de la luminancia media y del rango real de la foto.
enum AutoEnhance {

    private static let context = CIContext(options: [.cacheIntermediates: false])

    struct Stats {
        let mean: Double        // 0–1
        let darkest: Double
        let brightest: Double
        var range: Double { brightest - darkest }
    }

    static func measure(_ image: UIImage) throws -> Stats {
        guard let cg = image.cgImage else { throw ForgeError.decodeFailed }
        let ci = CIImage(cgImage: cg)
        let extent = CIVector(x: ci.extent.minX, y: ci.extent.minY,
                              z: ci.extent.width, w: ci.extent.height)

        func sample(_ filterName: String) throws -> [Double] {
            guard let f = CIFilter(name: filterName) else {
                throw ForgeError.filterFailed(filterName)
            }
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(extent, forKey: kCIInputExtentKey)
            guard let out = f.outputImage else {
                throw ForgeError.filterFailed(filterName)
            }
            var px = [UInt8](repeating: 0, count: 4)
            context.render(out, toBitmap: &px, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return px.map { Double($0) / 255.0 }
        }

        let avg = try sample("CIAreaAverage")
        let minMax = try? sample("CIAreaMinMax")

        // Luminancia perceptual, no el promedio plano de canales.
        let mean = 0.2126 * avg[0] + 0.7152 * avg[1] + 0.0722 * avg[2]

        let darkest = minMax.map { min($0[0], min($0[1], $0[2])) } ?? 0
        let brightest = minMax.map { max($0[0], max($0[1], $0[2])) } ?? 1

        return Stats(mean: max(0.001, mean),
                     darkest: darkest,
                     brightest: max(darkest + 0.01, brightest))
    }

    /// Ajustes propuestos, conservando lo que el usuario ya tocó a mano
    /// en geometría.
    static func suggest(for image: UIImage,
                        keeping current: Adjustments.Options) throws -> Adjustments.Options {
        let s = try measure(image)
        var o = current

        // Exposición: llevar la media hacia 0.45, que es donde cae una
        // escena bien expuesta. Se limita para no quemar ni aplastar.
        let target = 0.45
        let ev = log2(target / s.mean)
        o.exposure = min(1.2, max(-1.2, ev))

        // Contraste: si la foto no usa todo el rango, se estira un poco.
        let spread = s.range
        o.contrast = spread < 0.75 ? min(1.25, 1 + (0.75 - spread) * 0.5) : 1.0

        // Negros: solo si de verdad hay velo en las sombras.
        o.blackPoint = s.darkest > 0.06 ? min(0.08, (s.darkest - 0.06) * 0.6) : 0

        // Sombras arriba en escenas oscuras, altas luces abajo en claras.
        o.shadows = s.mean < 0.35 ? min(0.5, (0.35 - s.mean) * 2) : 0
        o.highlights = s.mean > 0.6 ? max(0.6, 1 - (s.mean - 0.6)) : 1

        // Un toque de intensidad, que satura menos los tonos de piel que
        // subir la saturación entera.
        o.vibrance = 0.15

        return o
    }
}
