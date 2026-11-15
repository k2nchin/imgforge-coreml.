import CoreGraphics
import simd

/// Trazador de bordes sobre la rejilla de píxeles.
///
/// Sigue la **frontera entre píxeles**, no sus centros. Es la diferencia
/// que separa esto de un trazado casero: recorriendo centros, una esquina
/// de 90° se corta en diagonal y queda comida; recorriendo la frontera,
/// la esquina es exacta. Es lo que hace potrace, y por eso Illustrator
/// devuelve ángulos rectos de verdad.
enum ContourTracer {

    /// Lado máximo de la rejilla analizada.
    static let maxEdge = 3000

    struct Contour {
        /// Puntos normalizados, origen arriba-izquierda.
        let points: [SIMD2<Float>]
        /// Área normalizada con signo: el signo da el sentido de giro.
        let area: Float
    }

    /// - Parameter threshold: nivel de corte 0–255, o `nil` para calcularlo
    ///   con el método de Otsu sobre el histograma de la imagen.
    static func trace(mask cg: CGImage, threshold: UInt8? = nil) throws -> [Contour] {
        let (grid, w, h) = try rasterize(cg, threshold: threshold)
        guard w >= 2, h >= 2 else { return [] }

        // La rejilla se consulta con origen abajo, como el espacio de
        // coordenadas en el que se definen los giros.
        func fg(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < w, y < h else { return false }
            return grid[(h - 1 - y) * w + x]
        }

        var usedEdges = Set<Int>()
        var out: [Contour] = []

        let fw = Float(w), fh = Float(h)
        let maxSteps = (w + 1) * (h + 1) * 4

        for y in 0..<h {
            for x in 0..<w {
                // Arranque: píxel activo cuyo vecino izquierdo es fondo.
                // Su arista izquierda es un borde, y se recorre hacia arriba.
                guard fg(x, y), !fg(x - 1, y) else { continue }
                let key = edgeKey(x: x, y: y, dir: 0, w: w)
                guard !usedEdges.contains(key) else { continue }

                var points: [SIMD2<Float>] = []
                var px = x, py = y
                var dir = 0                    // 0 arriba, 1 derecha, 2 abajo, 3 izquierda
                var steps = 0

                repeat {
                    usedEdges.insert(edgeKey(x: px, y: py, dir: dir, w: w))
                    points.append(SIMD2(Float(px) / fw, 1 - Float(py) / fh))

                    // Invariante: el relleno queda a la derecha del avance.
                    let (lx, ly) = frontLeft(px, py, dir)
                    let (rx, ry) = frontRight(px, py, dir)

                    if !fg(rx, ry) {
                        dir = (dir + 1) & 3            // girar a la derecha
                    } else if fg(lx, ly) {
                        dir = (dir + 3) & 3            // girar a la izquierda
                    }

                    let step = delta(dir)
                    px += step.0
                    py += step.1

                    steps += 1
                    if steps > maxSteps { break }

                } while !(px == x && py == y)

                guard points.count >= 4 else { continue }
                out.append(Contour(points: points, area: signedArea(points)))
            }
        }
        return out
    }

    // MARK: - Geometría del recorrido

    /// Arista que sale del vértice (x, y) en una dirección, como clave única.
    private static func edgeKey(x: Int, y: Int, dir: Int, w: Int) -> Int {
        ((y * (w + 1)) + x) * 4 + dir
    }

    private static func delta(_ dir: Int) -> (Int, Int) {
        switch dir {
        case 0:  return (0, 1)
        case 1:  return (1, 0)
        case 2:  return (0, -1)
        default: return (-1, 0)
        }
    }

    /// Píxel que toca la arista siguiente por el lado izquierdo del avance.
    private static func frontLeft(_ x: Int, _ y: Int, _ dir: Int) -> (Int, Int) {
        switch dir {
        case 0:  return (x - 1, y)
        case 1:  return (x, y)
        case 2:  return (x, y - 1)
        default: return (x - 1, y - 1)
        }
    }

    /// Y el que la toca por la derecha.
    private static func frontRight(_ x: Int, _ y: Int, _ dir: Int) -> (Int, Int) {
        switch dir {
        case 0:  return (x, y)
        case 1:  return (x, y - 1)
        case 2:  return (x - 1, y - 1)
        default: return (x - 1, y)
        }
    }

    // MARK: - Rejilla

    private static func rasterize(_ cg: CGImage,
                                  threshold: UInt8?) throws -> ([Bool], Int, Int) {
        let longest = max(cg.width, cg.height)
        let f = min(1.0, CGFloat(maxEdge) / CGFloat(longest))
        let w = max(1, Int((CGFloat(cg.width) * f).rounded()))
        let h = max(1, Int((CGFloat(cg.height) * f).rounded()))

        var bytes = [UInt8](repeating: 0, count: w * h)
        var ok = false

        bytes.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(
                      data: base, width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: w,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return }
            // Al reducir hace falta promediar: con vecino más próximo el
            // borde queda escalonado y el trazo hereda esos dientes.
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            ok = true
        }
        guard ok else { throw ForgeError.renderFailed }

        let cut = threshold ?? otsu(bytes)
        return (bytes.map { $0 >= cut }, w, h)
    }

    /// Umbral de Otsu: el corte que mejor separa los dos grupos del
    /// histograma. Un 128 fijo falla en cuanto el fondo no es blanco puro.
    static func otsu(_ bytes: [UInt8]) -> UInt8 {
        guard !bytes.isEmpty else { return 128 }

        var histogram = [Int](repeating: 0, count: 256)
        for b in bytes { histogram[Int(b)] += 1 }

        let total = bytes.count
        var sum = 0.0
        for i in 0..<256 { sum += Double(i) * Double(histogram[i]) }

        var sumBackground = 0.0
        var weightBackground = 0
        var best = 0.0
        var cut = 128

        for t in 0..<256 {
            weightBackground += histogram[t]
            if weightBackground == 0 { continue }
            let weightForeground = total - weightBackground
            if weightForeground == 0 { break }

            sumBackground += Double(t) * Double(histogram[t])
            let meanBackground = sumBackground / Double(weightBackground)
            let meanForeground = (sum - sumBackground) / Double(weightForeground)

            let between = Double(weightBackground) * Double(weightForeground)
                * (meanBackground - meanForeground) * (meanBackground - meanForeground)
            if between > best {
                best = between
                cut = t
            }
        }
        return UInt8(min(255, max(1, cut)))
    }

    // MARK: - Geometría

    /// Fórmula del cordón de zapato. Conserva el signo.
    static func signedArea(_ pts: [SIMD2<Float>]) -> Float {
        guard pts.count >= 3 else { return 0 }
        var acc: Float = 0
        for i in pts.indices {
            let a = pts[i]
            let b = pts[(i + 1) % pts.count]
            acc += a.x * b.y - b.x * a.y
        }
        return acc * 0.5
    }

    /// Ramer–Douglas–Peucker sobre un contorno cerrado.
    static func simplify(_ pts: [SIMD2<Float>], epsilon: Float) -> [SIMD2<Float>] {
        guard pts.count > 3, epsilon > 0 else { return pts }

        var farIndex = 0
        var farDist: Float = -1
        let head = pts[0]
        for (i, p) in pts.enumerated() {
            let d = simd_length_squared(p - head)
            if d > farDist { farDist = d; farIndex = i }
        }
        guard farIndex > 0 else { return pts }

        let first = Array(pts[0...farIndex])
        let second = Array(pts[farIndex...]) + [pts[0]]

        var out = rdp(first, epsilon)
        let tail = rdp(second, epsilon)
        if tail.count > 2 {
            out.append(contentsOf: tail.dropFirst().dropLast())
        }
        return out.count >= 3 ? out : pts
    }

    private static func rdp(_ pts: [SIMD2<Float>], _ epsilon: Float) -> [SIMD2<Float>] {
        guard pts.count > 2 else { return pts }

        let a = pts.first!
        let b = pts.last!
        var maxD: Float = 0
        var index = 0

        for i in 1..<(pts.count - 1) {
            let d = perpendicular(pts[i], a, b)
            if d > maxD { maxD = d; index = i }
        }

        guard maxD > epsilon else { return [a, b] }

        let left = rdp(Array(pts[0...index]), epsilon)
        let right = rdp(Array(pts[index...]), epsilon)
        return left.dropLast() + right
    }

    private static func perpendicular(_ p: SIMD2<Float>,
                                      _ a: SIMD2<Float>,
                                      _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let len = simd_length(ab)
        guard len > 1e-9 else { return simd_length(p - a) }
        return abs(ab.x * (a.y - p.y) - (a.x - p.x) * ab.y) / len
    }
}
