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

    /// Las curvas existen para pesar menos que la polilínea equivalente
    /// a igual nivel de simplificación.
    func testCurvesBeatPolylineAtSameDetail() throws {
        var poly = Vectorizer.Options()
        poly.curves = false
        poly.simplify = 0.0005

        var curved = poly
        curved.curves = true

        let a = try Vectorizer.run(shape, options: poly)
        let b = try Vectorizer.run(shape, options: curved)
        XCTAssertLessThan(b.byteCount, a.byteCount)
    }
}

final class EnvironmentTests: XCTestCase {

    func testMemoryBudgetIsSane() {
        let p = ForgeEnvironment.maxOutputPixels
        XCTAssertGreaterThanOrEqual(p, 4_000_000)
        XCTAssertLessThanOrEqual(p, 24_000_000,
                                 "Un techo alto mata la app antes de dibujar")
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
