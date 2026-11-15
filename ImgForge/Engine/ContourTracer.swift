import CoreGraphics
import simd

/// Trazador de bordes propio, sobre la rejilla de píxeles a resolución completa.
///
/// Vision recorta a 1024 px y entrega contornos suavizados de antemano.
/// Esto sigue el borde píxel a píxel (vecindad de Moore con criterio de
/// Jacob), que es lo que hacen potrace y vtracer, y preserva el detalle
/// real de la máscara.
enum ContourTracer {

    /// Lado máximo de la rejilla analizada. Por encima se reduce, porque
    /// el coste es lineal en el perímetro y una foto de 48 MP produce
    /// cientos de miles de puntos sin ganancia visible.
    static let maxEdge = 2048

    struct Contour {
        /// Puntos en coordenadas normalizadas, origen arriba-izquierda.
        let points: [SIMD2<Float>]
        /// Área normalizada con signo: el signo indica el sentido de giro.
        let area: Float
    }

    /// Extrae todos los bordes cerrados de una máscara en escala de grises.
    /// Los contornos anidados salen tal cual; con `fill-rule="evenodd"`
    /// los interiores se convierten en huecos sin trabajo extra.
    static func trace(mask cg: CGImage, threshold: UInt8 = 128) throws -> [Contour] {
        let (grid, w, h) = try rasterize(cg, threshold: threshold)
        guard w > 2, h > 2 else { return [] }

        var visited = [Bool](repeating: false, count: w * h)
        var out: [Contour] = []

        let fw = Float(w)
        let fh = Float(h)

        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard grid[i], !visited[i] else { continue }

                // Solo arranca en un píxel cuyo vecino izquierdo es fondo:
                // ese es un borde todavía no recorrido.
                let leftIsBackground = (x == 0) || !grid[i - 1]
                guard leftIsBackground else { continue }

                let path = follow(grid: grid, w: w, h: h,
                                  startX: x, startY: y, visited: &visited)
                guard path.count >= 4 else { continue }

                let pts = path.map { SIMD2<Float>(Float($0.0) / fw, Float($0.1) / fh) }
                let a = signedArea(pts)
                out.append(Contour(points: pts, area: a))
            }
        }
        return out
    }

    // MARK: - Rejilla

    private static func rasterize(_ cg: CGImage,
                                  threshold: UInt8) throws -> ([Bool], Int, Int) {
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
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            ok = true
        }
        guard ok else { throw ForgeError.renderFailed }

        return (bytes.map { $0 >= threshold }, w, h)
    }

    // MARK: - Vecindad de Moore

    /// Los ocho vecinos en sentido horario, empezando por el oeste.
    private static let neighbors: [(Int, Int)] = [
        (-1, 0), (-1, -1), (0, -1), (1, -1),
        (1, 0), (1, 1), (0, 1), (-1, 1)
    ]

    private static func follow(grid: [Bool], w: Int, h: Int,
                               startX: Int, startY: Int,
                               visited: inout [Bool]) -> [(Int, Int)] {
        var path: [(Int, Int)] = []

        var cx = startX
        var cy = startY
        // Se llegó al inicio desde el oeste.
        var entry = 0

        let maxSteps = w * h * 4
        var steps = 0

        repeat {
            path.append((cx, cy))
            visited[cy * w + cx] = true

            // Se reanuda la vuelta justo después del vecino por el que se entró.
            var found = false
            for k in 1...8 {
                let dir = (entry + k) % 8
                let nx = cx + neighbors[dir].0
                let ny = cy + neighbors[dir].1

                guard nx >= 0, ny >= 0, nx < w, ny < h, grid[ny * w + nx] else { continue }

                // La dirección de entrada al nuevo píxel es la opuesta.
                entry = (dir + 4) % 8
                cx = nx
                cy = ny
                found = true
                break
            }

            // Píxel aislado: no hay borde que seguir.
            if !found { break }

            steps += 1
            if steps > maxSteps { break }

        } while !(cx == startX && cy == startY)

        return path
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
    /// Sustituye a `polygonApproximation` de Vision, que ya no se usa.
    static func simplify(_ pts: [SIMD2<Float>], epsilon: Float) -> [SIMD2<Float>] {
        guard pts.count > 3, epsilon > 0 else { return pts }

        // Un contorno cerrado se parte en dos cadenas por sus extremos
        // más distantes, para que el algoritmo tenga anclas estables.
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
