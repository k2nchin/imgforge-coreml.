import CoreML
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Super-resolución por Core ML. Busca `RealESRGAN.mlmodelc` en el bundle.
/// Sin el modelo, `isAvailable` es false y el motor clásico toma el relevo.
enum NeuralUpscaler {

    static let modelName = "RealESRGAN"
    static let nativeScale: CGFloat = 4
    static var tile: Int { ForgeEnvironment.neuralTile }
    static let overlap = 48

    private static var cached: MLModel?

    static var isAvailable: Bool {
        guard ForgeEnvironment.allowsNeural else { return false }
        return Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") != nil
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

    /// Amplía a `options.scale` componiendo **directamente sobre el lienzo
    /// final**.
    ///
    /// Antes se construía el lienzo 4× entero y se reducía al final, lo que
    /// no cabía en memoria para una imagen grande; la alternativa era
    /// reducir la entrada antes de pasarla al modelo, y eso tiraba detalle
    /// real para que el modelo lo reinventara después: en un logo con
    /// texto, las letras salían blandas. Ahora cada baldosa se infiere a 4×
    /// y se reduce a su hueco definitivo al dibujarla, así que el modelo
    /// siempre ve los píxeles originales y la memoria nunca pasa del
    /// tamaño pedido.
    static func run(_ cg: CGImage,
                    options: Upscaler.Options,
                    context: CIContext,
                    isCancelled: () -> Bool = { false }) throws -> UIImage {
        guard ForgeEnvironment.allowsNeural else {
            throw ForgeError.modelMissing(modelName)
        }
        let m = try model()

        let scale = options.scale
        let outW = max(1, Int((CGFloat(cg.width) * scale).rounded()))
        let outH = max(1, Int((CGFloat(cg.height) * scale).rounded()))

        guard outW * outH <= ForgeEnvironment.maxOutputPixels else {
            throw ForgeError.tooLarge(pixels: outW * outH,
                                      limit: ForgeEnvironment.maxOutputPixels)
        }

        guard let canvas = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ForgeError.renderFailed }

        canvas.interpolationQuality = .high

        let tiles = plan(width: cg.width, height: cg.height)
        let ramp = max(1, Int((CGFloat(overlap) * scale).rounded()))
        let native = Int(nativeScale)

        for t in tiles {
            if isCancelled() { throw ForgeError.cancelled }

            guard let piece = cg.cropping(to: t) else { throw ForgeError.renderFailed }
            let padded = try infer(piece, model: m, context: context)

            // La baldosa se rellenó al tamaño que el modelo exige; la
            // región útil queda arriba a la izquierda.
            let useful = CGRect(x: 0, y: 0,
                                width: Int(t.width) * native,
                                height: Int(t.height) * native)
            guard let up = padded.cropping(to: useful) else {
                throw ForgeError.renderFailed
            }

            // Hueco en el lienzo final, en coordenadas con origen abajo.
            let dest = CGRect(
                x: (t.minX * scale).rounded(),
                y: ((CGFloat(cg.height) - t.maxY) * scale).rounded(),
                width: (t.width * scale).rounded(),
                height: (t.height * scale).rounded()
            )
            guard dest.width >= 1, dest.height >= 1 else { continue }

            let mask = feather(
                width: Int(dest.width), height: Int(dest.height), ramp: ramp,
                left: t.minX > 0,
                right: Int(t.maxX) < cg.width,
                top: t.minY > 0,
                bottom: Int(t.maxY) < cg.height
            )

            canvas.saveGState()
            if let mask {
                canvas.clip(to: dest, mask: mask)
            } else {
                canvas.clip(to: dest)
            }
            canvas.draw(up, in: dest)
            canvas.restoreGState()
        }

        guard let out = canvas.makeImage() else { throw ForgeError.renderFailed }
        return UIImage(cgImage: out)
    }

    // MARK: - Baldosas

    private static func plan(width: Int, height: Int) -> [CGRect] {
        guard width > tile || height > tile else {
            return [CGRect(x: 0, y: 0, width: width, height: height)]
        }
        var out: [CGRect] = []
        let step = max(1, tile - overlap)
        var y = 0
        while y < height {
            let h = min(tile, height - y)
            var x = 0
            while x < width {
                let w = min(tile, width - x)
                out.append(CGRect(x: x, y: y, width: w, height: h))
                if x + w >= width { break }
                x += step
            }
            if y + h >= height { break }
            y += step
        }
        return out
    }

    /// Máscara en escala de grises: 255 en el centro, rampa lineal hasta 0
    /// en los lados que tienen vecina. Fila 0 es la de arriba, igual que
    /// el espacio de imagen en el que se calculan las banderas.
    private static func feather(width: Int, height: Int, ramp: Int,
                                left: Bool, right: Bool,
                                top: Bool, bottom: Bool) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard left || right || top || bottom else { return nil }

        let r = max(1, min(ramp, min(width, height) / 2))
        var bytes = [UInt8](repeating: 255, count: width * height)

        for y in 0..<height {
            var vY: Float = 1
            if top, y < r { vY = min(vY, Float(y) / Float(r)) }
            if bottom, y >= height - r { vY = min(vY, Float(height - 1 - y) / Float(r)) }

            for x in 0..<width {
                var v = vY
                if left, x < r { v = min(v, Float(x) / Float(r)) }
                if right, x >= width - r { v = min(v, Float(width - 1 - x) / Float(r)) }
                if v < 1 {
                    bytes[y * width + x] = UInt8(max(0, min(255, v * 255)))
                }
            }
        }

        return bytes.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(
                      data: base, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return nil }
            return ctx.makeImage()
        }
    }

    // MARK: - Inferencia

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

    /// El modelo espera exactamente `tile`×`tile`. Una baldosa de borde es
    /// más pequeña, así que se centra en un lienzo del tamaño pedido.
    private static func pixelBuffer(from cg: CGImage) -> CVPixelBuffer? {
        let side = tile
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, side, side,
            kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: side, height: side,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        ctx.draw(cg, in: CGRect(x: 0, y: side - cg.height,
                                width: cg.width, height: cg.height))
        return buffer
    }
}
