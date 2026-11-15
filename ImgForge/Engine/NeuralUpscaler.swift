import CoreML
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Super-resolución por Core ML. Busca `RealESRGAN.mlmodelc` en el bundle.
/// Sin el modelo, `isAvailable` es false y el motor clásico toma el relevo.
enum NeuralUpscaler {

    static let modelName = "RealESRGAN"
    static let nativeScale: CGFloat = 4
    static let tile = 512
    static let overlap = 32

    private static var cached: MLModel?

    static var isAvailable: Bool {
        Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") != nil
    }

    private static func model() throws -> MLModel {
        if let cached { return cached }
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
            throw ForgeError.modelMissing(modelName)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            let m = try MLModel(contentsOf: url, configuration: config)
            cached = m
            return m
        } catch {
            throw ForgeError.modelLoadFailed(error.localizedDescription)
        }
    }

    static func run(_ cg: CGImage,
                    options: Upscaler.Options,
                    context: CIContext) throws -> UIImage {
        let m = try model()
        let tiles = plan(width: cg.width, height: cg.height)

        let outW = cg.width * Int(nativeScale)
        let outH = cg.height * Int(nativeScale)

        guard let canvas = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ForgeError.renderFailed }

        for t in tiles {
            guard let piece = cg.cropping(to: t) else { throw ForgeError.renderFailed }
            let up = try infer(piece, model: m, context: context)
            let dest = CGRect(
                x: t.minX * nativeScale,
                y: (CGFloat(cg.height) - t.maxY) * nativeScale,
                width: t.width * nativeScale,
                height: t.height * nativeScale
            )
            canvas.draw(up, in: dest)
        }

        guard let base = canvas.makeImage() else { throw ForgeError.renderFailed }

        guard abs(options.scale - nativeScale) > 0.01 else {
            return UIImage(cgImage: base)
        }

        let factor = options.scale / nativeScale
        let scaled = try Upscaler.resize(CIImage(cgImage: base),
                                         scale: factor, method: .lanczos)
        let rect = CGRect(x: 0, y: 0,
                          width: CGFloat(outW) * factor,
                          height: CGFloat(outH) * factor)
        guard let out = context.createCGImage(scaled, from: rect) else {
            throw ForgeError.renderFailed
        }
        return UIImage(cgImage: out)
    }

    // MARK: - Interna

    private static func plan(width: Int, height: Int) -> [CGRect] {
        guard width > tile || height > tile else {
            return [CGRect(x: 0, y: 0, width: width, height: height)]
        }
        var out: [CGRect] = []
        let step = tile - overlap
        var y = 0
        while y < height {
            var x = 0
            let h = min(tile, height - y)
            while x < width {
                let w = min(tile, width - x)
                out.append(CGRect(x: x, y: y, width: w, height: h))
                x += step
            }
            y += step
        }
        return out
    }

    private static func infer(_ piece: CGImage,
                              model: MLModel,
                              context: CIContext) throws -> CGImage {
        guard let buffer = pixelBuffer(from: piece) else { throw ForgeError.renderFailed }
        let input = try MLDictionaryFeatureProvider(
            dictionary: ["input": MLFeatureValue(pixelBuffer: buffer)]
        )

        let out: MLFeatureProvider
        do {
            out = try model.prediction(from: input)
        } catch {
            throw ForgeError.inferenceFailed(error.localizedDescription)
        }

        guard let pb = out.featureValue(for: "output")?.imageBufferValue else {
            throw ForgeError.inferenceFailed("salida 'output' ausente")
        }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = context.createCGImage(ci, from: ci.extent) else {
            throw ForgeError.renderFailed
        }
        return cg
    }

    private static func pixelBuffer(from cg: CGImage) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, cg.width, cg.height,
            kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: cg.width, height: cg.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return buffer
    }
}
