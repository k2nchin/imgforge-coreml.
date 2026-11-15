import CoreGraphics
import simd

/// Ajusta cúbicas a una polilínea (Schneider). Menos puntos, trazo más limpio.
enum BezierFitter {

    typealias Cubic = (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)

    /// Ajusta un contorno cerrado.
    ///
    /// `cornerAngle` es el giro mínimo, en grados, que convierte un punto en
    /// esquina. En una esquina el ajuste se parte: las tangentes a cada lado
    /// quedan libres y el vértice sale afilado, en vez de redondeado. Es lo
    /// que hace el deslizador Esquinas de Image Trace, y es la diferencia
    /// entre un logo que parece trazado y uno que parece derretido.
    static func fit(_ points: [SIMD2<Float>],
                    error: Float,
                    cornerAngle: Float = 60) -> String {
        guard points.count > 3 else { return polyline(points) }

        let errSq = error * error
        let corners = detectCorners(points, threshold: cornerAngle)

        guard corners.count >= 2 else {
            // Curva sin esquinas: un solo ajuste cerrado.
            var out = "M\(fmt(points[0].x)) \(fmt(points[0].y))"
            let t1 = normalize(points[1] - points[0])
            let t2 = normalize(points[points.count - 2] - points[points.count - 1])
            fitCubic(points, 0, points.count - 1, t1, t2, errSq, &out, depth: 0)
            return out + " Z"
        }

        let start = points[corners[0]]
        var out = "M\(fmt(start.x)) \(fmt(start.y))"

        for k in corners.indices {
            let a = corners[k]
            let b = corners[(k + 1) % corners.count]
            let chain = subchain(points, from: a, to: b)
            guard chain.count >= 2 else { continue }

            if chain.count == 2 {
                let e = chain[1]
                out += " L\(fmt(e.x)) \(fmt(e.y))"
                continue
            }

            let t1 = normalize(chain[1] - chain[0])
            let t2 = normalize(chain[chain.count - 2] - chain[chain.count - 1])
            fitCubic(chain, 0, chain.count - 1, t1, t2, errSq, &out, depth: 0)
        }
        return out + " Z"
    }

    /// Un vértice es esquina cuando la dirección gira más que el umbral.
    private static func detectCorners(_ p: [SIMD2<Float>],
                                      threshold: Float) -> [Int] {
        let n = p.count
        guard n >= 4 else { return [] }

        let limit = cos(threshold * .pi / 180)
        var corners: [Int] = []

        for i in 0..<n {
            let prev = p[(i - 1 + n) % n]
            let next = p[(i + 1) % n]
            let v1 = normalize(p[i] - prev)
            let v2 = normalize(next - p[i])
            guard simd_length(v1) > 0, simd_length(v2) > 0 else { continue }

            // dot = 1 es recto; cuanto menor, más cerrado el giro.
            if simd_dot(v1, v2) < limit {
                // Dos esquinas pegadas son ruido de rasterizado: basta una.
                if let last = corners.last, i - last < 2 { continue }
                corners.append(i)
            }
        }
        return corners
    }

    /// Tramo cerrado de `from` a `to`, dando la vuelta si hace falta.
    private static func subchain(_ p: [SIMD2<Float>],
                                 from a: Int, to b: Int) -> [SIMD2<Float>] {
        if a < b { return Array(p[a...b]) }
        return Array(p[a...]) + Array(p[0...b])
    }

    private static func fitCubic(_ p: [SIMD2<Float>], _ first: Int, _ last: Int,
                                 _ t1: SIMD2<Float>, _ t2: SIMD2<Float>,
                                 _ errSq: Float, _ out: inout String, depth: Int) {
        let n = last - first + 1

        if n == 2 {
            let d = simd_length(p[last] - p[first]) / 3
            emit(p[first] + t1 * d, p[last] + t2 * d, p[last], &out)
            return
        }

        var u = chordParams(p, first, last)
        var bez = generate(p, first, last, u, t1, t2)
        var (maxErr, split) = maxError(p, first, last, bez, u)

        if maxErr < errSq {
            emit(bez.1, bez.2, bez.3, &out)
            return
        }

        if maxErr < errSq * 4 && depth < 8 {
            for _ in 0..<4 {
                u = reparam(p, first, last, u, bez)
                bez = generate(p, first, last, u, t1, t2)
                (maxErr, split) = maxError(p, first, last, bez, u)
                if maxErr < errSq {
                    emit(bez.1, bez.2, bez.3, &out)
                    return
                }
            }
        }

        guard depth < 16, split > first, split < last else {
            emit(bez.1, bez.2, bez.3, &out)
            return
        }
        let center = normalize(p[split - 1] - p[split + 1])
        fitCubic(p, first, split, t1, center, errSq, &out, depth: depth + 1)
        fitCubic(p, split, last, -center, t2, errSq, &out, depth: depth + 1)
    }

    // MARK: - Álgebra

    private static func generate(_ p: [SIMD2<Float>], _ first: Int, _ last: Int,
                                 _ u: [Float],
                                 _ t1: SIMD2<Float>, _ t2: SIMD2<Float>) -> Cubic {
        let n = last - first + 1
        var c00: Float = 0, c01: Float = 0, c11: Float = 0
        var x0: Float = 0, x1: Float = 0

        for i in 0..<n {
            let ui = i < u.count ? u[i] : 1
            let a1 = t1 * b1(ui)
            let a2 = t2 * b2(ui)
            c00 += simd_dot(a1, a1)
            c01 += simd_dot(a1, a2)
            c11 += simd_dot(a2, a2)

            let tmp = p[first + i] - (p[first] * (b0(ui) + b1(ui))
                                      + p[last] * (b2(ui) + b3(ui)))
            x0 += simd_dot(a1, tmp)
            x1 += simd_dot(a2, tmp)
        }

        let det = c00 * c11 - c01 * c01
        var alpha1: Float = 0, alpha2: Float = 0
        if abs(det) > 1e-9 {
            alpha1 = (x0 * c11 - c01 * x1) / det
            alpha2 = (c00 * x1 - x0 * c01) / det
        }
        let seg = simd_length(p[last] - p[first])
        if alpha1 < 1e-6 || alpha2 < 1e-6 {
            alpha1 = seg / 3
            alpha2 = seg / 3
        }

        return (p[first], p[first] + t1 * alpha1, p[last] + t2 * alpha2, p[last])
    }

    private static func chordParams(_ p: [SIMD2<Float>],
                                    _ first: Int, _ last: Int) -> [Float] {
        var u: [Float] = [0]
        guard last > first else { return u }
        for i in (first + 1)...last {
            u.append(u[i - first - 1] + simd_length(p[i] - p[i - 1]))
        }
        let total = u.last ?? 1
        return total > 0 ? u.map { $0 / total } : u
    }

    private static func reparam(_ p: [SIMD2<Float>], _ first: Int, _ last: Int,
                                _ u: [Float], _ bez: Cubic) -> [Float] {
        (first...last).map { i in
            let ui = (i - first) < u.count ? u[i - first] : 1
            return newton(p[i], ui, bez)
        }
    }

    private static func newton(_ q: SIMD2<Float>, _ u: Float, _ b: Cubic) -> Float {
        let d = eval(b, u) - q
        let d1 = (b.1 - b.0) * 3
        let d2 = (b.2 - b.1) * 3
        let d3 = (b.3 - b.2) * 3
        let q1 = d1 * (1 - u) * (1 - u) + d2 * 2 * (1 - u) * u + d3 * u * u
        let q2 = (d2 - d1) * 2 * (1 - u) + (d3 - d2) * 2 * u
        let den = simd_dot(q1, q1) + simd_dot(d, q2)
        return abs(den) < 1e-9 ? u : u - simd_dot(d, q1) / den
    }

    private static func maxError(_ p: [SIMD2<Float>], _ first: Int, _ last: Int,
                                 _ b: Cubic, _ u: [Float]) -> (Float, Int) {
        var maxD: Float = 0
        var idx = (first + last) / 2
        guard last > first + 1 else { return (0, idx) }
        for i in (first + 1)..<last {
            let ui = (i - first) < u.count ? u[i - first] : 1
            let d = simd_length_squared(eval(b, ui) - p[i])
            if d > maxD { maxD = d; idx = i }
        }
        return (maxD, idx)
    }

    private static func eval(_ b: Cubic, _ t: Float) -> SIMD2<Float> {
        b.0 * b0(t) + b.1 * b1(t) + b.2 * b2(t) + b.3 * b3(t)
    }

    private static func b0(_ t: Float) -> Float { let m = 1 - t; return m * m * m }
    private static func b1(_ t: Float) -> Float { let m = 1 - t; return 3 * t * m * m }
    private static func b2(_ t: Float) -> Float { let m = 1 - t; return 3 * t * t * m }
    private static func b3(_ t: Float) -> Float { t * t * t }

    private static func normalize(_ v: SIMD2<Float>) -> SIMD2<Float> {
        let l = simd_length(v)
        return l > 1e-9 ? v / l : SIMD2(0, 0)
    }

    // MARK: - Salida

    private static func emit(_ c1: SIMD2<Float>, _ c2: SIMD2<Float>,
                             _ end: SIMD2<Float>, _ out: inout String) {
        out += " C\(fmt(c1.x)) \(fmt(c1.y)) \(fmt(c2.x)) \(fmt(c2.y)) \(fmt(end.x)) \(fmt(end.y))"
    }

    private static func polyline(_ p: [SIMD2<Float>]) -> String {
        guard let head = p.first else { return "" }
        var d = "M\(fmt(head.x)) \(fmt(head.y))"
        for q in p.dropFirst() {
            d += " L\(fmt(q.x)) \(fmt(q.y))"
        }
        return d + " Z"
    }

    private static func fmt(_ v: Float) -> String { String(format: "%.4f", v) }
}
