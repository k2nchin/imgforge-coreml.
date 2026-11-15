import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum Upscaler {

    static var maxOutputPixels: Int { ForgeEnvironment.maxOutputPixels }

    enum Method: String, CaseIterable, Identifiable, Hashable {
        case lanczos = "Lanczos"
        case bicubic = "Bicúbico"
        case nearest = "Nearest"
        var id: String { rawValue }
    }

    enum Engine: String, CaseIterable, Identifiable, Hashable {
        case auto = "Auto"
        case classic = "Clásico"
        case neural = "Neural"
        var id: String { rawValue }
    }

    struct Options: Hashable {
        var scale: CGFloat = 2.0
        var method: Method = .lanczos
        var sharpen: Float = 0.0
        var noiseReduction: Bool = false
        var engine: Engine = .auto
    }

    enum Quality {
        case draft(maxEdge: Int)
        case full
    }

    static let context: CIContext = {
        CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    }()

    // MARK: - Entrada

    struct Outcome {
        let image: UIImage
        let engine: Engine
    }

    /// La ruta neural siempre cabe si la salida pedida cabe: cuando el
    /// lienzo 4× no entra en memoria, la entrada se reduce antes para que
    /// el 4× del modelo aterrice exactamente en el tamaño pedido.
    static func neuralFits(_ cg: CGImage, scale: CGFloat) -> Bool {
        Int(CGFloat(cg.width) * scale) * Int(CGFloat(cg.height) * scale)
            <= ForgeEnvironment.maxOutputPixels
    }

    /// Decide qué se le da al modelo.
    ///
    /// El modelo multiplica por 4 y nada más. Para una escala menor hay
    /// dos caminos: ampliar 4× y reducir después, que da mejor resultado
    /// pero necesita el lienzo grande en memoria; o reducir la entrada
    /// antes, que cabe siempre. Se prefiere el primero cuando entra.
    private static func prepareNeural(_ cg: CGImage,
                                      scale: CGFloat) throws -> (CGImage, CGFloat) {
        let fourTimes = cg.width * cg.height * 16
        if fourTimes <= ForgeEnvironment.maxOutputPixels || scale >= NeuralUpscaler.nativeScale {
            return (cg, scale)
        }

        let pre = scale / NeuralUpscaler.nativeScale     // < 1
        let w = max(1, Int((CGFloat(cg.width) * pre).rounded()))
        let h = max(1, Int((CGFloat(cg.height) * pre).rounded()))

        let shrunk = try resize(CIImage(cgImage: cg), scale: pre, method: .lanczos)
        guard let out = context.createCGImage(
            shrunk, from: CGRect(x: 0, y: 0, width: w, height: h)
        ) else { throw ForgeError.renderFailed }

        // Ya reducida, el 4× del modelo da el tamaño pedido: sin reescalar después.
        return (out, NeuralUpscaler.nativeScale)
    }

    static func run(_ input: UIImage,
                    options: Options,
                    quality: Quality = .full,
                    isCancelled: () -> Bool = { false }) throws -> UIImage {
        try runDetailed(input, options: options,
                        quality: quality, isCancelled: isCancelled).image
    }

    static func runDetailed(_ input: UIImage,
                            options: Options,
                            quality: Quality = .full,
                            isCancelled: () -> Bool = { false }) throws -> Outcome {
        guard let cg = input.cgImage else { throw ForgeError.decodeFailed }

        if case .draft(let maxEdge) = quality {
            return Outcome(image: try draft(cg, options: options, maxEdge: maxEdge),
                           engine: .classic)
        }

        let outW = Int(CGFloat(cg.width) * options.scale)
        let outH = Int(CGFloat(cg.height) * options.scale)
        guard outW > 0, outH > 0 else { throw ForgeError.decodeFailed }
        guard outW * outH <= maxOutputPixels else {
            throw ForgeError.tooLarge(pixels: outW * outH, limit: maxOutputPixels)
        }

        let available = NeuralUpscaler.isAvailable

        func neural() throws -> UIImage {
            let (input, factor) = try prepareNeural(cg, scale: options.scale)
            var opts = options
            opts.scale = factor
            return try NeuralUpscaler.run(input, options: opts,
                                          context: context,
                                          isCancelled: isCancelled)
        }

        switch options.engine {
        case .neural:
            guard available else {
                throw ForgeError.modelMissing(NeuralUpscaler.modelName)
            }
            return Outcome(image: try neural(), engine: .neural)

        case .auto where available:
            do {
                return Outcome(image: try neural(), engine: .neural)
            } catch ForgeError.cancelled {
                throw ForgeError.cancelled
            } catch {
                // El modelo falló; el motor clásico sigue siendo válido.
            }

        default:
            break
        }

        if isCancelled() { throw ForgeError.cancelled }

        let image = try classic(cg, options: options,
                                size: CGSize(width: outW, height: outH))
        return Outcome(image: image, engine: .classic)
    }

    // MARK: - Draft

    private static func draft(_ cg: CGImage,
                              options: Options,
                              maxEdge: Int) throws -> UIImage {
        let longest = max(cg.width, cg.height)
        let shrink = min(1.0, CGFloat(maxEdge) / (CGFloat(longest) * options.scale))

        var image = CIImage(cgImage: cg)
        if shrink < 1.0 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = image
            f.scale = Float(shrink)
            f.aspectRatio = 1
            guard let out = f.outputImage else {
                throw ForgeError.filterFailed("draft shrink")
            }
            image = out
        }

        var opts = options
        opts.noiseReduction = false
        image = try chain(image, options: opts)

        let w = max(1, Int(CGFloat(cg.width) * options.scale * shrink))
        let h = max(1, Int(CGFloat(cg.height) * options.scale * shrink))
        guard let out = context.createCGImage(
            image, from: CGRect(x: 0, y: 0, width: w, height: h)
        ) else { throw ForgeError.renderFailed }
        return UIImage(cgImage: out)
    }

    // MARK: - Clásico

    private static func classic(_ cg: CGImage,
                                options: Options,
                                size: CGSize) throws -> UIImage {
        let image = try chain(CIImage(cgImage: cg), options: options)
        guard let out = context.createCGImage(
            image, from: CGRect(origin: .zero, size: size)
        ) else { throw ForgeError.renderFailed }
        return UIImage(cgImage: out)
    }

    private static func chain(_ source: CIImage, options: Options) throws -> CIImage {
        var image = source

        if options.noiseReduction {
            let nr = CIFilter.noiseReduction()
            nr.inputImage = image
            nr.noiseLevel = 0.02
            nr.sharpness = 0.4
            guard let out = nr.outputImage else {
                throw ForgeError.filterFailed("noiseReduction")
            }
            image = out
        }

        image = try resize(image, scale: options.scale, method: options.method)

        if options.sharpen > 0 {
            let um = CIFilter.unsharpMask()
            um.inputImage = image
            um.radius = 2.5
            um.intensity = options.sharpen
            guard let out = um.outputImage else {
                throw ForgeError.filterFailed("unsharpMask")
            }
            image = out
        }
        return image
    }

    static func resize(_ image: CIImage, scale: CGFloat, method: Method) throws -> CIImage {
        switch method {
        case .lanczos:
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = image
            f.scale = Float(scale)
            f.aspectRatio = 1
            guard let o = f.outputImage else { throw ForgeError.filterFailed("lanczos") }
            return o
        case .bicubic:
            let f = CIFilter.bicubicScaleTransform()
            f.inputImage = image
            f.scale = Float(scale)
            f.aspectRatio = 1
            f.parameterB = 0
            f.parameterC = 0.75
            guard let o = f.outputImage else { throw ForgeError.filterFailed("bicubic") }
            return o
        case .nearest:
            return image
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .samplingNearest()
        }
    }
}
