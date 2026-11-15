import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum Upscaler {

    static let maxOutputPixels = 64_000_000

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

    static func run(_ input: UIImage,
                    options: Options,
                    quality: Quality = .full) throws -> UIImage {
        guard let cg = input.cgImage else { throw ForgeError.decodeFailed }

        if case .draft(let maxEdge) = quality {
            return try draft(cg, options: options, maxEdge: maxEdge)
        }

        let outW = Int(CGFloat(cg.width) * options.scale)
        let outH = Int(CGFloat(cg.height) * options.scale)
        guard outW > 0, outH > 0 else { throw ForgeError.decodeFailed }
        guard outW * outH <= maxOutputPixels else {
            throw ForgeError.tooLarge(pixels: outW * outH, limit: maxOutputPixels)
        }

        let useNeural: Bool
        switch options.engine {
        case .neural:
            useNeural = true
        case .classic:
            useNeural = false
        case .auto:
            useNeural = NeuralUpscaler.isAvailable && cg.width * cg.height <= 4_000_000
        }

        if useNeural {
            do {
                return try NeuralUpscaler.run(cg, options: options, context: context)
            } catch {
                if options.engine == .neural { throw error }
            }
        }
        return try classic(cg, options: options,
                           size: CGSize(width: outW, height: outH))
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
