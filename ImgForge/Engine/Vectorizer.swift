import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import simd

enum Vectorizer {

    enum ColorMode: Hashable {
        case mono
        case palette(Int)
    }

    struct Options: Hashable {
        var simplify: Float = 0.002
        var minArea: Float = 0.0005
        var colorMode: ColorMode = .mono
        var curves: Bool = true
        var curveError: Float = 0.004
        /// Giro mínimo en grados para tratar un vértice como esquina.
        var cornerAngle: Float = 60
        /// Rutas contiguas: ensancha cada capa un píxel para que no quede
        /// una grieta entre colores vecinos.
        var abutting: Bool = true
        /// Mediana previa, contra el moteado del borde antialiasado.
        var denoise: Bool = true
        var invert: Bool = false
        var strokeOnly: Bool = false
        var strokeWidth: Double = 1.0
        var monoInk: String = "#000000"
        /// Nivel de corte 0–255. `nil` lo calcula Otsu sobre el histograma,
        /// que es lo que hace el deslizador Umbral de Image Trace cuando
        /// se deja en automático.
        var threshold: Int? = nil
    }

    struct Result {
        let svg: String
        let pathCount: Int
        let byteCount: Int
        let palette: [String]
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func run(_ input: UIImage,
                    options: Options,
                    isCancelled: () -> Bool = { false }) throws -> Result {
        guard let cg = input.cgImage else { throw ForgeError.decodeFailed }

        var groups: [(fill: String, paths: [String])] = []

        switch options.colorMode {
        case .mono:
            let prepared = try preprocess(cg, invert: options.invert,
                                          denoise: options.denoise)
            groups.append((options.monoInk, try trace(prepared, options: options)))

        case .palette(let k):
            let layers = try ColorQuantizer.layers(from: cg, count: k,
                                                   dilate: options.abutting,
                                                   denoise: options.denoise)
            for layer in layers {
                if isCancelled() { throw ForgeError.cancelled }
                guard let paths = try? trace(layer.mask, options: options),
                      !paths.isEmpty else { continue }
                groups.append((layer.hex, paths))
            }
        }

        let total = groups.reduce(0) { $0 + $1.paths.count }
        guard total > 0 else { throw ForgeError.noContours }

        let svg = assemble(groups: groups,
                           width: cg.width, height: cg.height,
                           options: options)
        return Result(svg: svg,
                      pathCount: total,
                      byteCount: svg.utf8.count,
                      palette: groups.map(\.fill))
    }

    // MARK: - Trazado

    private static func trace(_ cg: CGImage, options: Options) throws -> [String] {
        let contours = try ContourTracer.trace(
            mask: cg,
            threshold: options.threshold.map { UInt8(max(1, min(255, $0))) })
        guard !contours.isEmpty else { return [] }

        var out: [String] = []
        for c in contours {
            // El área viene con signo; para filtrar manchas importa el tamaño.
            guard abs(c.area) >= options.minArea else { continue }

            let pts = ContourTracer.simplify(c.points, epsilon: options.simplify)
            guard pts.count >= 3 else { continue }

            out.append(options.curves
                       ? BezierFitter.fit(pts,
                                          error: options.curveError,
                                          cornerAngle: options.cornerAngle)
                       : polyline(pts))
        }
        return out
    }

    /// Monocromo y, por defecto, invertido: el trazador busca regiones
    /// en blanco, y en un logo la tinta es lo oscuro.
    private static func preprocess(_ cg: CGImage,
                                   invert: Bool,
                                   denoise: Bool) throws -> CGImage {
        var input = CIImage(cgImage: cg)
        if denoise {
            let m = CIFilter.median()
            m.inputImage = input
            if let out = m.outputImage { input = out.cropped(to: input.extent) }
        }
        let mono = CIFilter.photoEffectMono()
        mono.inputImage = input
        guard var out = mono.outputImage else { throw ForgeError.filterFailed("mono") }

        if !invert {
            let f = CIFilter.colorInvert()
            f.inputImage = out
            guard let i = f.outputImage else { throw ForgeError.filterFailed("invert") }
            out = i
        }
        guard let result = context.createCGImage(out, from: out.extent) else {
            throw ForgeError.renderFailed
        }
        return result
    }

    // MARK: - Serialización

    private static func assemble(groups: [(fill: String, paths: [String])],
                                 width: Int, height: Int,
                                 options: Options) -> String {
        var svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" \
        viewBox="0 0 1 1" preserveAspectRatio="none" shape-rendering="geometricPrecision">

        """
        for g in groups {
            let w = options.strokeWidth / Double(max(width, 1))
            let style = options.strokeOnly
                ? "fill=\"none\" stroke=\"\(g.fill)\" stroke-width=\"\(w)\" stroke-linejoin=\"round\""
                : "fill=\"\(g.fill)\" fill-rule=\"evenodd\" stroke=\"none\""
            svg += "<g \(style)>\n"
            for p in g.paths { svg += "<path d=\"\(p)\"/>\n" }
            svg += "</g>\n"
        }
        return svg + "</svg>\n"
    }

    private static func polyline(_ pts: [SIMD2<Float>]) -> String {
        var d = ""
        for (i, p) in pts.enumerated() {
            let x = String(format: "%.4f", p.x)
            let y = String(format: "%.4f", p.y)
            d += (i == 0 ? "M\(x) \(y)" : " L\(x) \(y)")
        }
        return d + " Z"
    }

}
