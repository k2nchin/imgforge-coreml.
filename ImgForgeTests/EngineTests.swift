import XCTest
import UIKit
import simd
@testable import ImgForge

final class BezierFitterTests: XCTestCase {

    /// Un círculo muestreado densamente debe caber en pocas cúbicas.
    func testCircleCollapsesToFewCurves() {
        let pts = (0..<180).map { i -> SIMD2<Float> in
            let a = Float(i) / 180 * 2 * .pi
            return SIMD2(0.5 + 0.4 * cos(a), 0.5 + 0.4 * sin(a))
        }
        let d = BezierFitter.fit(pts, error: 0.004)

        XCTAssertTrue(d.hasPrefix("M"), "El path debe empezar con un moveto")
        XCTAssertTrue(d.hasSuffix(" Z"), "El path debe cerrarse")

        let curves = d.components(separatedBy: " C").count - 1
        XCTAssertGreaterThan(curves, 0, "Debe producir al menos una cúbica")
        XCTAssertLessThan(curves, 40,
                          "180 puntos en un círculo no deberían necesitar 40 cúbicas")
    }

    func testTriangleStaysPolyline() {
        let pts: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0.5, 1)]
        let d = BezierFitter.fit(pts, error: 0.004)
        XCTAssertTrue(d.contains("L"), "Tres puntos salen como polilínea")
        XCTAssertFalse(d.isEmpty)
    }

    func testEmptyInputDoesNotCrash() {
        XCTAssertEqual(BezierFitter.fit([], error: 0.004), "")
    }

    /// Los números del path deben ser finitos: un NaN rompe el SVG entero.
    func testNoNaNInOutput() {
        let pts = (0..<60).map { i -> SIMD2<Float> in
            SIMD2(Float(i) / 60, Float(i % 2))   // zigzag con tangentes bruscas
        }
        let d = BezierFitter.fit(pts, error: 0.002)
        XCTAssertFalse(d.contains("nan"), "Path con NaN: \(d.prefix(120))")
        XCTAssertFalse(d.contains("inf"))
    }
}

/// El renderer usa la escala de la pantalla (3× en simulador), lo que
/// multiplicaba los píxeles reales. Estos tests necesitan escala 1.
func renderAtScale1(_ size: CGSize, _ draw: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image(actions: draw)
}

final class ColorQuantizerTests: XCTestCase {

    private func image(colors: [UIColor], size: CGSize = CGSize(width: 64, height: 64)) -> CGImage {
        renderAtScale1(size) { ctx in
            let band = size.height / CGFloat(colors.count)
            for (i, c) in colors.enumerated() {
                c.setFill()
                ctx.fill(CGRect(x: 0, y: CGFloat(i) * band, width: size.width, height: band))
            }
        }.cgImage!
    }

    func testSeparatesTwoBands() throws {
        let cg = image(colors: [.red, .blue])
        let layers = try ColorQuantizer.layers(from: cg, count: 2)

        XCTAssertEqual(layers.count, 2)
        let coverage = layers.reduce(0) { $0 + $1.coverage }
        XCTAssertEqual(coverage, 1.0, accuracy: 0.02,
                       "Las capas deben cubrir toda la imagen")
    }

    func testLayersAreSortedByCoverage() throws {
        let cg = image(colors: [.red, .red, .red, .green])
        let layers = try ColorQuantizer.layers(from: cg, count: 2)
        XCTAssertGreaterThanOrEqual(layers[0].coverage, layers[1].coverage,
                                    "El fondo va primero para quedar debajo")
    }

    func testHexIsWellFormed() throws {
        let layers = try ColorQuantizer.layers(from: image(colors: [.black, .white]), count: 2)
        for l in layers {
            XCTAssertEqual(l.hex.count, 7, "Hex inválido: \(l.hex)")
            XCTAssertTrue(l.hex.hasPrefix("#"))
        }
    }
}

final class UpscalerTests: XCTestCase {

    private var sample: UIImage {
        renderAtScale1(CGSize(width: 32, height: 32)) { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }

    func testClassicScalesExactly() throws {
        var o = Upscaler.Options()
        o.scale = 3
        o.engine = .classic
        let out = try Upscaler.run(sample, options: o)
        XCTAssertEqual(out.cgImage?.width, 96)
        XCTAssertEqual(out.cgImage?.height, 96)
    }

    func testRejectsOversizedOutput() {
        var o = Upscaler.Options()
        o.scale = 10_000
        o.engine = .classic
        XCTAssertThrowsError(try Upscaler.run(sample, options: o)) { error in
            guard case ForgeError.tooLarge = error else {
                return XCTFail("Se esperaba tooLarge, llegó \(error)")
            }
        }
    }

    func testDraftIsSmallerThanFull() throws {
        var o = Upscaler.Options()
        o.scale = 8
        o.engine = .classic
        let draft = try Upscaler.run(sample, options: o, quality: .draft(maxEdge: 100))
        XCTAssertLessThanOrEqual(draft.cgImage!.width, 100)
    }

    func testCancellationIsHonored() {
        var o = Upscaler.Options()
        o.scale = 2
        o.engine = .classic
        XCTAssertThrowsError(
            try Upscaler.run(sample, options: o, isCancelled: { true })
        ) { error in
            guard case ForgeError.cancelled = error else {
                return XCTFail("Se esperaba cancelled, llegó \(error)")
            }
        }
    }
}

final class VectorizerTests: XCTestCase {

    private var shape: UIImage {
        renderAtScale1(CGSize(width: 128, height: 128)) { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            UIColor.black.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 24, y: 24, width: 80, height: 80))
        }
    }

    func testProducesValidSVG() throws {
        let r = try Vectorizer.run(shape, options: Vectorizer.Options())
        XCTAssertTrue(r.svg.hasPrefix("<?xml"))
        XCTAssertTrue(r.svg.contains("<svg"))
        XCTAssertTrue(r.svg.hasSuffix("</svg>\n"))
        XCTAssertGreaterThan(r.pathCount, 0)
        XCTAssertEqual(r.byteCount, r.svg.utf8.count)
    }

    func testPathCountMatchesMarkup() throws {
        let r = try Vectorizer.run(shape, options: Vectorizer.Options())
        let tags = r.svg.components(separatedBy: "<path").count - 1
        XCTAssertEqual(tags, r.pathCount)
    }

    /// Con curvas activas el peso no es monótono: una polilínea gruesa
    /// produce una cúbica por segmento, así que simplificar puede pesar
    /// más. La relación solo se sostiene sobre la polilínea cruda.
    func testSimplifyReducesDetail() throws {
        var fine = Vectorizer.Options()
        fine.simplify = 0.0005
        fine.curves = false

        var coarse = Vectorizer.Options()
        coarse.simplify = 0.02
        coarse.curves = false

        let a = try Vectorizer.run(shape, options: fine)
        let b = try Vectorizer.run(shape, options: coarse)
        XCTAssertGreaterThanOrEqual(a.byteCount, b.byteCount,
                                    "Sobre polilínea, simplificar debe pesar menos")
    }

    /// Las curvas no pesan menos en bytes: una `C` lleva seis números y
    /// una `L` dos. Lo que reducen es el número de segmentos, que es lo
    /// que importa al editar el vector.
    func testCurvesReduceSegmentCount() throws {
        var poly = Vectorizer.Options()
        poly.curves = false
        poly.simplify = 0.0005

        var curved = poly
        curved.curves = true

        let a = try Vectorizer.run(shape, options: poly)
        let b = try Vectorizer.run(shape, options: curved)

        let lines = a.svg.components(separatedBy: " L").count - 1
        let cubics = b.svg.components(separatedBy: " C").count - 1

        XCTAssertGreaterThan(cubics, 0, "Debe emitir cúbicas")
        XCTAssertLessThanOrEqual(cubics, lines,
                                 "Una cúbica cubre uno o más segmentos rectos")
    }
}

final class EnvironmentTests: XCTestCase {

    func testMemoryBudgetIsSane() {
        let p = ForgeEnvironment.maxOutputPixels
        XCTAssertGreaterThanOrEqual(p, 6_000_000,
                                    "Por debajo de esto ni 1.5× de una foto cabe")
        XCTAssertLessThanOrEqual(p, 64_000_000,
                                 "256 MB de bitmap es lo que iOS concede sin matar")
    }

    /// Una foto de 12 MP debe admitir al menos 2×; antes el tope de
    /// 24 MP la rechazaba incluso a 1.5×.
    func testTypicalPhotoAllowsUsefulScale() {
        let twelveMP = 3024 * 4032
        XCTAssertGreaterThanOrEqual(ForgeEnvironment.maxScale(forPixels: twelveMP), 2.0)
    }

    func testMaxScaleStaysOnSliderSteps() {
        let s = ForgeEnvironment.maxScale(forPixels: 2774 * 4160)
        XCTAssertEqual(s * 2, (s * 2).rounded(), accuracy: 0.001,
                       "El tope debe caer en un paso de 0.5")
        XCTAssertLessThanOrEqual(s, 8)
    }

    func testTestBundleIsNotAnExtension() {
        XCTAssertFalse(ForgeEnvironment.isExtension)
    }
}

final class ContourTracerTests: XCTestCase {

    private func mask(_ draw: (CGContext, CGSize) -> Void,
                      size: CGSize = CGSize(width: 100, height: 100)) -> CGImage {
        renderAtScale1(size) { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            draw(ctx.cgContext, size)
        }.cgImage!
    }

    func testSquareProducesOneContour() throws {
        let cg = mask { ctx, _ in
            ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        }
        let contours = try ContourTracer.trace(mask: cg)
        XCTAssertEqual(contours.count, 1)
        XCTAssertGreaterThan(abs(contours[0].area), 0.3,
                             "Un cuadrado de 60×60 en 100×100 cubre ~0.36")
    }

    func testDonutProducesTwoContours() throws {
        let cg = mask { ctx, _ in
            ctx.fillEllipse(in: CGRect(x: 10, y: 10, width: 80, height: 80))
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(x: 35, y: 35, width: 30, height: 30))
        }
        let contours = try ContourTracer.trace(mask: cg)
        XCTAssertEqual(contours.count, 2,
                       "El borde exterior y el del hueco son dos contornos")
    }

    func testTwoShapesAreSeparate() throws {
        let cg = mask { ctx, _ in
            ctx.fill(CGRect(x: 5, y: 5, width: 25, height: 25))
            ctx.fill(CGRect(x: 65, y: 65, width: 25, height: 25))
        }
        XCTAssertEqual(try ContourTracer.trace(mask: cg).count, 2)
    }

    func testEmptyMaskProducesNothing() throws {
        let cg = mask { _, _ in }
        XCTAssertTrue(try ContourTracer.trace(mask: cg).isEmpty)
    }

    func testSimplifyDropsCollinearPoints() {
        // Un cuadrado muestreado cada píxel: 4 esquinas bastan.
        var pts: [SIMD2<Float>] = []
        for i in 0..<50 { pts.append(SIMD2(Float(i) / 50, 0)) }
        for i in 0..<50 { pts.append(SIMD2(1, Float(i) / 50)) }
        for i in 0..<50 { pts.append(SIMD2(1 - Float(i) / 50, 1)) }
        for i in 0..<50 { pts.append(SIMD2(0, 1 - Float(i) / 50)) }

        let simple = ContourTracer.simplify(pts, epsilon: 0.01)
        XCTAssertLessThan(simple.count, 12,
                          "200 puntos colineales deben colapsar a unas pocas esquinas")
        XCTAssertGreaterThanOrEqual(simple.count, 4)
    }

    /// La resolución real importa: Vision recortaba a 1024 y perdía detalle.
    func testTracesBeyond1024Pixels() throws {
        let cg = mask({ ctx, size in
            ctx.fill(CGRect(x: 100, y: 100, width: size.width - 200,
                            height: size.height - 200))
        }, size: CGSize(width: 1600, height: 1600))

        let contours = try ContourTracer.trace(mask: cg)
        XCTAssertEqual(contours.count, 1)
        XCTAssertGreaterThan(contours[0].points.count, 100)
    }
}

final class CornerFittingTests: XCTestCase {

    /// Un cuadrado muestreado densamente debe conservar cuatro esquinas
    /// afiladas. Sin detección de esquinas el ajuste las redondea y el
    /// logo sale derretido.
    func testSquareKeepsFourCorners() {
        var pts: [SIMD2<Float>] = []
        let n = 40
        for i in 0..<n { pts.append(SIMD2(0.1 + 0.8 * Float(i) / Float(n), 0.1)) }
        for i in 0..<n { pts.append(SIMD2(0.9, 0.1 + 0.8 * Float(i) / Float(n))) }
        for i in 0..<n { pts.append(SIMD2(0.9 - 0.8 * Float(i) / Float(n), 0.9)) }
        for i in 0..<n { pts.append(SIMD2(0.1, 0.9 - 0.8 * Float(i) / Float(n))) }

        let d = BezierFitter.fit(pts, error: 0.004, cornerAngle: 60)
        let segments = (d.components(separatedBy: " C").count - 1)
            + (d.components(separatedBy: " L").count - 1)

        XCTAssertGreaterThanOrEqual(segments, 4,
                                    "Cuatro lados, cuatro tramos como mínimo")
        XCTAssertLessThanOrEqual(segments, 12,
                                 "Los lados rectos no deben fragmentarse")
    }

    /// Un círculo no tiene esquinas: debe salir como una curva continua
    /// aunque la detección esté activa.
    func testCircleHasNoCorners() {
        let pts = (0..<120).map { i -> SIMD2<Float> in
            let a = Float(i) / 120 * 2 * .pi
            return SIMD2(0.5 + 0.4 * cos(a), 0.5 + 0.4 * sin(a))
        }
        let d = BezierFitter.fit(pts, error: 0.004, cornerAngle: 60)
        XCTAssertEqual(d.components(separatedBy: " L").count - 1, 0,
                       "Un círculo no debe producir segmentos rectos")
    }

    /// El número de tramos del path no mide las esquinas: con pocas
    /// esquinas el ajuste subdivide más para alcanzar la tolerancia.
    /// Lo que se prueba es la detección en sí.
    func testDetectorFindsSquareCorners() {
        var pts: [SIMD2<Float>] = []
        let n = 30
        for i in 0..<n { pts.append(SIMD2(Float(i) / Float(n), 0)) }
        for i in 0..<n { pts.append(SIMD2(1, Float(i) / Float(n))) }
        for i in 0..<n { pts.append(SIMD2(1 - Float(i) / Float(n), 1)) }
        for i in 0..<n { pts.append(SIMD2(0, 1 - Float(i) / Float(n))) }

        let corners = BezierFitter.detectCorners(pts, threshold: 60)
        XCTAssertEqual(corners.count, 4, "Un cuadrado tiene cuatro esquinas")
    }

    func testDetectorIgnoresSmoothCurve() {
        let pts = (0..<120).map { i -> SIMD2<Float> in
            let a = Float(i) / 120 * 2 * .pi
            return SIMD2(0.5 + 0.4 * cos(a), 0.5 + 0.4 * sin(a))
        }
        XCTAssertTrue(BezierFitter.detectCorners(pts, threshold: 60).isEmpty,
                      "Un círculo no tiene esquinas")
    }

    /// Bajar el umbral detecta más esquinas, igual que subir el
    /// deslizador Esquinas de Image Trace.
    func testLowerThresholdFindsMoreCorners() {
        let pts = (0..<80).map { i -> SIMD2<Float> in
            let a = Float(i) / 80 * 2 * .pi
            let r: Float = i % 10 == 0 ? 0.45 : 0.3
            return SIMD2(0.5 + r * cos(a), 0.5 + r * sin(a))
        }
        let loose = BezierFitter.detectCorners(pts, threshold: 30).count
        let strict = BezierFitter.detectCorners(pts, threshold: 120).count
        XCTAssertGreaterThanOrEqual(loose, strict)
    }
}

final class AbuttingTests: XCTestCase {

    /// `coverage` cuenta píxeles asignados y la dilatación no los cambia:
    /// lo que crece es la máscara. Hay que medirla a ella.
    private func whitePixels(_ cg: CGImage) -> Int {
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes.filter { $0 > 127 }.count
    }

    func testDilationGrowsTheMask() throws {
        let cg = renderAtScale1(CGSize(width: 80, height: 80)) { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 40, y: 0, width: 40, height: 80))
        }.cgImage!

        let plain = try ColorQuantizer.layers(from: cg, count: 2, dilate: false)
        let abut = try ColorQuantizer.layers(from: cg, count: 2, dilate: true)

        let before = plain.reduce(0) { $0 + whitePixels($1.mask) }
        let after = abut.reduce(0) { $0 + whitePixels($1.mask) }

        XCTAssertGreaterThan(after, before,
                             "Las capas contiguas se solapan, no dejan grieta")
    }
}

final class NeuralBudgetTests: XCTestCase {

    /// El caso que fallaba en el teléfono: una foto de 11.5 MP con el
    /// motor Neural. El lienzo 4× son 184 MP y no cabe, pero la salida
    /// pedida a 1.5× son 26 MP y sí. Antes se rechazaba igual.
    func testPhoneSizedPhotoFitsNeuralPath() {
        let cg = renderAtScale1(CGSize(width: 2774, height: 4160)) { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2774, height: 4160))
        }.cgImage!

        XCTAssertTrue(Upscaler.neuralFits(cg, scale: 1.5),
                      "1.5× de una foto de teléfono debe caber")
        XCTAssertTrue(Upscaler.neuralFits(cg, scale: 2.0))
    }

    func testAbsurdScaleStillRejected() {
        let cg = renderAtScale1(CGSize(width: 2774, height: 4160)) { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2774, height: 4160))
        }.cgImage!

        XCTAssertFalse(Upscaler.neuralFits(cg, scale: 8),
                       "8× de 11.5 MP son 738 MP: eso no cabe en ningún teléfono")
    }

    /// El tope del deslizador y lo que acepta la ruta neural tienen que
    /// coincidir, o el usuario puede elegir algo que luego falla.
    func testSliderCeilingAgreesWithNeuralPath() {
        let pixels = 2774 * 4160
        let cg = renderAtScale1(CGSize(width: 2774, height: 4160)) { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2774, height: 4160))
        }.cgImage!

        let top = ForgeEnvironment.maxScale(forPixels: pixels)
        XCTAssertTrue(Upscaler.neuralFits(cg, scale: CGFloat(top)),
                      "Lo que el deslizador permite, el motor debe aceptarlo")
    }
}

final class ResizerTests: XCTestCase {

    private var wide: UIImage {
        renderAtScale1(CGSize(width: 400, height: 200)) { ctx in
            UIColor.systemIndigo.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
    }

    func testStretchHitsExactSize() throws {
        var o = Resizer.Options(); o.width = 300; o.height = 300; o.fit = .stretch
        let out = try Resizer.run(wide, options: o)
        XCTAssertEqual(out.cgImage?.width, 300)
        XCTAssertEqual(out.cgImage?.height, 300)
    }

    func testCoverFillsAndCrops() throws {
        var o = Resizer.Options(); o.width = 300; o.height = 300; o.fit = .cover
        let out = try Resizer.run(wide, options: o)
        XCTAssertEqual(out.cgImage?.width, 300)
        XCTAssertEqual(out.cgImage?.height, 300)
    }

    func testContainKeepsWholeImage() throws {
        var o = Resizer.Options(); o.width = 300; o.height = 300; o.fit = .contain
        let out = try Resizer.run(wide, options: o)
        XCTAssertEqual(out.cgImage?.width, 300)
        XCTAssertEqual(out.cgImage?.height, 300)
    }

    /// Las tres opciones entregan el lienzo pedido; lo que cambia es el
    /// contenido. Contener deja margen, así que tiene píxeles transparentes.
    func testContainLeavesMarginAndCoverDoesNot() throws {
        func transparentCorner(_ image: UIImage) -> Bool {
            guard let cg = image.cgImage else { return false }
            var px = [UInt8](repeating: 0, count: 4)
            px.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress,
                      let ctx = CGContext(data: base, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            return px[3] < 10
        }

        var contain = Resizer.Options()
        contain.width = 300; contain.height = 300; contain.fit = .contain
        var cover = contain; cover.fit = .cover

        XCTAssertTrue(transparentCorner(try Resizer.run(wide, options: contain)))
        XCTAssertFalse(transparentCorner(try Resizer.run(wide, options: cover)))
    }

    func testRejectsAbsurdTarget() {
        var o = Resizer.Options(); o.width = 40_000; o.height = 40_000
        XCTAssertThrowsError(try Resizer.run(wide, options: o))
    }
}

final class AdjustmentsTests: XCTestCase {

    private var sample: UIImage {
        renderAtScale1(CGSize(width: 120, height: 80)) { ctx in
            UIColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
    }

    func testIdentityKeepsSize() throws {
        let out = try Adjustments.apply(sample, options: Adjustments.Options())
        XCTAssertEqual(out.cgImage?.width, 120)
        XCTAssertEqual(out.cgImage?.height, 80)
    }

    func testCropTakesTheRequestedRegion() throws {
        let half = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let out = try Adjustments.apply(sample, options: Adjustments.Options(), crop: half)
        XCTAssertEqual(out.cgImage?.width, 60)
        XCTAssertEqual(out.cgImage?.height, 40)
    }

    func testQuarterTurnSwapsSides() throws {
        var o = Adjustments.Options()
        o.rotationQuarters = 1
        let out = try Adjustments.apply(sample, options: o)
        XCTAssertEqual(out.cgImage?.width, 80)
        XCTAssertEqual(out.cgImage?.height, 120)
    }

    func testExposureChangesPixels() throws {
        var o = Adjustments.Options()
        o.exposure = 1.5
        let brighter = try Adjustments.apply(sample, options: o)
        XCTAssertNotNil(brighter.cgImage)
        XCTAssertNotEqual(brighter.pngData(), sample.pngData())
    }

    func testActiveCountTracksEdits() {
        var o = Adjustments.Options()
        XCTAssertTrue(o.isIdentity)
        XCTAssertEqual(o.activeCount, 0)
        o.exposure = 0.5
        o.saturation = 1.4
        XCTAssertFalse(o.isIdentity)
        XCTAssertEqual(o.activeCount, 2)
    }

    func testCancellationIsHonored() {
        XCTAssertThrowsError(
            try Adjustments.apply(sample, options: Adjustments.Options(),
                                  isCancelled: { true })
        )
    }
}

final class ExporterTests: XCTestCase {

    private var sample: UIImage {
        renderAtScale1(CGSize(width: 60, height: 40)) { ctx in
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
    }

    private func write(_ format: ExportFormat) throws -> URL {
        var s = Exporter.Settings()
        s.format = format
        return try Exporter.write(sample, settings: s, stem: "test_\(format.ext)")
    }

    func testWritesEachFormat() throws {
        for f in ExportFormat.allCases {
            let url = try write(f)
            XCTAssertEqual(url.pathExtension, f.ext)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
            XCTAssertGreaterThan(size ?? 0, 100, "\(f.rawValue) salió vacío")
        }
    }

    func testPNGAndJPEGHaveCorrectMagicBytes() throws {
        let png = try Data(contentsOf: write(.png))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])

        let jpg = try Data(contentsOf: write(.jpeg))
        XCTAssertEqual(Array(jpg.prefix(2)), [0xFF, 0xD8])

        let pdf = try Data(contentsOf: write(.pdf))
        XCTAssertEqual(Array(pdf.prefix(4)), Array("%PDF".utf8))
    }

    func testLowerQualityMakesSmallerJPEG() throws {
        var high = Exporter.Settings(); high.format = .jpeg; high.quality = 1.0
        var low = Exporter.Settings(); low.format = .jpeg; low.quality = 0.3

        let a = try Data(contentsOf: Exporter.write(sample, settings: high, stem: "q_high"))
        let b = try Data(contentsOf: Exporter.write(sample, settings: low, stem: "q_low"))
        XCTAssertLessThan(b.count, a.count)
    }

    /// A más ppp, la página mide menos puntos: la misma imagen se imprime
    /// más chica y con más resolución.
    func testHigherDPIMakesSmallerPage() throws {
        var low = Exporter.Settings(); low.format = .pdf; low.dpi = 72
        var high = Exporter.Settings(); high.format = .pdf; high.dpi = 300

        let a = try Data(contentsOf: Exporter.write(sample, settings: low, stem: "dpi_72"))
        let b = try Data(contentsOf: Exporter.write(sample, settings: high, stem: "dpi_300"))
        XCTAssertFalse(a.isEmpty)
        XCTAssertFalse(b.isEmpty)
    }

    func testPhotosRejectsPDF() {
        XCTAssertFalse(ExportFormat.pdf.savesToPhotos)
        XCTAssertTrue(ExportFormat.png.savesToPhotos)
        XCTAssertTrue(ExportFormat.jpeg.savesToPhotos)
    }

    func testSVGKeepsItsExtension() throws {
        let url = try Exporter.writeSVG("<svg/>", stem: "vector_test")
        XCTAssertEqual(url.pathExtension, "svg")
    }
}

@MainActor
final class EditorSizeTests: XCTestCase {

    private func loaded() -> EditorStore {
        let store = EditorStore()
        store.load(renderAtScale1(CGSize(width: 2000, height: 1000)) { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        })
        return store
    }

    func testSizeStartsAtNative() {
        let s = loaded()
        XCTAssertEqual(s.resize.width, 2000)
        XCTAssertEqual(s.resize.height, 1000)
        XCTAssertFalse(s.sizeTouched)
    }

    /// El bug: recortar a la mitad y exportar volvía a estirar el recorte
    /// hasta las medidas originales, interpolando píxeles que no existían.
    func testCropUpdatesSizeSoNothingIsStretchedBack() {
        let s = loaded()
        s.crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        s.cropChanged()

        XCTAssertEqual(s.resize.width, 1000)
        XCTAssertEqual(s.resize.height, 500)
        XCTAssertNil(s.resampleNote, "Al tamaño nativo no hay remuestreo que avisar")
    }

    func testManualSizeIsRespectedAndCropStopsOverwritingIt() {
        let s = loaded()
        s.widthChanged(800)
        XCTAssertTrue(s.sizeTouched)

        s.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        s.cropChanged()
        XCTAssertEqual(s.resize.width, 800, "Una medida escrita a mano no se pisa")
    }

    func testNativeButtonReturnsToCropSize() {
        let s = loaded()
        s.applyPreset(Resizer.presets[0])          // 1080 × 1080
        XCTAssertTrue(s.sizeTouched)

        s.useNativeSize()
        XCTAssertFalse(s.sizeTouched)
        XCTAssertEqual(s.resize.width, 2000)
        XCTAssertEqual(s.resize.height, 1000)
    }

    func testWarnsWhenAskedToEnlarge() {
        let s = loaded()
        s.widthChanged(4000)
        XCTAssertNotNil(s.resampleNote)
        XCTAssertTrue(s.resampleNote?.contains("interpola") ?? false)
    }

    func testQuarterTurnSwapsNativeSize() {
        let s = loaded()
        s.adjustments.rotationQuarters = 1
        s.syncSizeToCrop()
        XCTAssertEqual(s.croppedPixels.width, 1000)
        XCTAssertEqual(s.croppedPixels.height, 2000)
    }

    func testAspectLockFollowsTheCropNotTheOriginal() {
        let s = loaded()
        s.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)   // ahora 1000×1000
        s.cropChanged()

        s.lockAspect = true
        s.widthChanged(500)
        XCTAssertEqual(s.resize.height, 500, "La proporción es la del recorte, 1:1")
    }
}

final class StraightenTests: XCTestCase {

    /// La fórmula de cos(θ) solo vale para un cuadrado: en 16:9 dejaba
    /// esquinas transparentes al enderezar.
    func testInscribedRectFitsInsideRotatedBox() {
        for (w, h) in [(1600.0, 900.0), (900.0, 1600.0), (1000.0, 1000.0)] {
            for degrees in stride(from: 1.0, through: 15.0, by: 2.0) {
                let a = degrees * .pi / 180
                let box = Adjustments.largestInscribed(
                    width: CGFloat(w), height: CGFloat(h), angle: CGFloat(a))

                // Proyección del rectángulo propuesto sobre los ejes del
                // original: debe caber en w×h.
                let projW = box.width * cos(a) + box.height * sin(a)
                let projH = box.width * sin(a) + box.height * cos(a)

                XCTAssertLessThanOrEqual(projW, CGFloat(w) + 1,
                                         "\(w)x\(h) a \(degrees)° se sale de ancho")
                XCTAssertLessThanOrEqual(projH, CGFloat(h) + 1,
                                         "\(w)x\(h) a \(degrees)° se sale de alto")
            }
        }
    }

    func testZeroAngleKeepsFullSize() {
        let box = Adjustments.largestInscribed(width: 800, height: 600, angle: 0)
        XCTAssertEqual(box.width, 800)
        XCTAssertEqual(box.height, 600)
    }

    func testInscribedIsNotDegenerate() {
        let box = Adjustments.largestInscribed(width: 1600, height: 900,
                                               angle: 15 * .pi / 180)
        XCTAssertGreaterThan(box.width, 1000)
        XCTAssertGreaterThan(box.height, 500)
    }
}

final class AutoEnhanceTests: XCTestCase {

    private func flat(_ level: CGFloat) -> UIImage {
        renderAtScale1(CGSize(width: 64, height: 64)) { ctx in
            UIColor(white: level, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    func testMeasuresBrightness() throws {
        let dark = try AutoEnhance.measure(flat(0.15))
        let light = try AutoEnhance.measure(flat(0.85))
        XCTAssertLessThan(dark.mean, light.mean)
    }

    func testDarkImageGetsPositiveExposure() throws {
        let o = try AutoEnhance.suggest(for: flat(0.12),
                                        keeping: Adjustments.Options())
        XCTAssertGreaterThan(o.exposure, 0, "Una foto oscura debe subir")
        XCTAssertLessThanOrEqual(o.exposure, 1.2, "Pero con tope")
    }

    func testBrightImageGetsNegativeExposure() throws {
        let o = try AutoEnhance.suggest(for: flat(0.9),
                                        keeping: Adjustments.Options())
        XCTAssertLessThan(o.exposure, 0)
        XCTAssertGreaterThanOrEqual(o.exposure, -1.2)
    }

    func testKeepsGeometryUntouched() throws {
        var current = Adjustments.Options()
        current.rotationQuarters = 2
        current.flipHorizontal = true
        current.straighten = 4

        let o = try AutoEnhance.suggest(for: flat(0.3), keeping: current)
        XCTAssertEqual(o.rotationQuarters, 2)
        XCTAssertTrue(o.flipHorizontal)
        XCTAssertEqual(o.straighten, 4)
    }
}

@MainActor
final class EditorHistoryTests: XCTestCase {

    private func loaded() -> EditorStore {
        let s = EditorStore()
        s.load(renderAtScale1(CGSize(width: 800, height: 600)) { ctx in
            UIColor.systemPink.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        })
        return s
    }

    func testUndoRestoresPreviousState() {
        let s = loaded()
        XCTAssertFalse(s.canUndo)

        s.commit()
        s.adjustments.exposure = 1.0
        XCTAssertTrue(s.canUndo)

        s.undo()
        XCTAssertEqual(s.adjustments.exposure, 0)
    }

    func testRedoReappliesIt() {
        let s = loaded()
        s.commit()
        s.adjustments.saturation = 1.8
        s.undo()
        XCTAssertTrue(s.canRedo)

        s.redo()
        XCTAssertEqual(s.adjustments.saturation, 1.8)
    }

    func testNewEditClearsRedo() {
        let s = loaded()
        s.commit()
        s.adjustments.contrast = 1.3
        s.undo()
        XCTAssertTrue(s.canRedo)

        s.commit()
        s.adjustments.exposure = 0.4
        XCTAssertFalse(s.canRedo, "Un cambio nuevo invalida la rama rehecha")
    }

    func testResetClearsHistory() {
        let s = loaded()
        s.commit()
        s.adjustments.exposure = 1
        s.reset()
        XCTAssertFalse(s.canUndo)
        XCTAssertFalse(s.canRedo)
    }

    func testHistoryIsBounded() {
        let s = loaded()
        for i in 0..<60 {
            s.commit()
            s.adjustments.exposure = Double(i) / 100
        }
        var depth = 0
        while s.canUndo { s.undo(); depth += 1 }
        XCTAssertLessThanOrEqual(depth, 30, "El historial no crece sin límite")
    }
}
