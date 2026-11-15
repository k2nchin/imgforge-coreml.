import Vision
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
        var invert: Bool = false
        var strokeOnly: Bool = false
        var strokeWidth: Double = 1.0
        var monoInk: String = "#000000"
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
            let prepared = try preprocess(cg, invert: options.invert)
            groups.append((options.monoInk, try trace(prepared, options: options)))

        case .palette(let k):
            let layers = try ColorQuantizer.layers(from: cg, count: k)
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
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.0
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 1024

        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        } catch {
            throw ForgeError.visionFailed(error.localizedDescription)
        }

        guard let obs = request.results?.first as? VNContoursObservation else {
            throw ForgeError.noContours
        }

        let epsilon = max(Float(0.0001), options.simplify)
        var out: [String] = []

        /// La simplificación vive en VNContour, no en la observación,
        /// y se aplica contorno por contorno.
        func walk(_ contour: VNContour, depth: Int) {
            let simplified = (try? contour.polygonApproximation(epsilon: epsilon)) ?? contour
            let pts = simplified.normalizedPoints.map { SIMD2<Float>($0.x, 1 - $0.y) }

            if pts.count >= 3, area(pts) >= options.minArea {
                out.append(options.curves
                           ? BezierFitter.fit(pts, error: options.curveError)
                           : polyline(pts))
            }
            guard depth < 6 else { return }
            for child in contour.childContours {
                walk(child, depth: depth + 1)
            }
        }

        for contour in obs.topLevelContours {
            walk(contour, depth: 0)
        }
        return out
    }

    private static func preprocess(_ cg: CGImage, invert: Bool) throws -> CGImage {
        let mono = CIFilter.photoEffectMono()
        mono.inputImage = CIImage(cgImage: cg)
        guard var out = mono.outputImage else { throw ForgeError.filterFailed("mono") }

        if invert {
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

    private static func area(_ pts: [SIMD2<Float>]) -> Float {
        var acc: Float = 0
        for i in pts.indices {
            let a = pts[i]
            let b = pts[(i + 1) % pts.count]
            acc += a.x * b.y - b.x * a.y
        }
        return abs(acc) * 0.5
    }
}
