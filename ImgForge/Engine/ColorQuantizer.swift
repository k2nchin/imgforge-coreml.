import UIKit
import simd

/// Cuantiza una imagen a N colores y produce una máscara binaria por color.
enum ColorQuantizer {

    struct Layer {
        let color: UIColor
        let hex: String
        let mask: CGImage
        let coverage: Float
    }

    static func layers(from cg: CGImage, count k: Int, maxEdge: Int = 512) throws -> [Layer] {
        let k = max(2, min(32, k))

        let (pixels, w, h) = try sample(cg, maxEdge: maxEdge)
        guard !pixels.isEmpty else { throw ForgeError.decodeFailed }

        let labs = pixels.map(rgbToLab)
        var centers = seed(labs, k: k)
        var assign = [Int](repeating: 0, count: labs.count)

        for _ in 0..<16 {
            var moved = false
            for i in labs.indices {
                var best = 0
                var bestD = Float.greatestFiniteMagnitude
                for c in centers.indices {
                    let d = dist(labs[i], centers[c])
                    if d < bestD { bestD = d; best = c }
                }
                if assign[i] != best {
                    assign[i] = best
                    moved = true
                }
            }
            var sums = [SIMD3<Float>](repeating: .zero, count: k)
            var counts = [Int](repeating: 0, count: k)
            for i in labs.indices {
                sums[assign[i]] += labs[i]
                counts[assign[i]] += 1
            }
            for c in 0..<k where counts[c] > 0 {
                centers[c] = sums[c] / Float(counts[c])
            }
            if !moved { break }
        }

        var out: [Layer] = []
        for c in 0..<k {
            let members = assign.indices.filter { assign[$0] == c }
            guard !members.isEmpty else { continue }

            var r: Float = 0, g: Float = 0, b: Float = 0
            for i in members {
                r += pixels[i].x
                g += pixels[i].y
                b += pixels[i].z
            }
            let n = Float(members.count)
            r /= n; g /= n; b /= n

            guard let mask = buildMask(assign: assign, target: c, width: w, height: h) else {
                continue
            }

            out.append(Layer(
                color: UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1),
                hex: String(format: "#%02X%02X%02X",
                            Int(r * 255), Int(g * 255), Int(b * 255)),
                mask: mask,
                coverage: n / Float(assign.count)
            ))
        }
        // Las capas grandes van primero: se dibujan debajo.
        return out.sorted { $0.coverage > $1.coverage }
    }

    // MARK: - Muestreo

    private static func sample(_ cg: CGImage,
                               maxEdge: Int) throws -> ([SIMD3<Float>], Int, Int) {
        let longest = max(cg.width, cg.height)
        let f = min(1.0, CGFloat(maxEdge) / CGFloat(longest))
        let w = max(1, Int(CGFloat(cg.width) * f))
        let h = max(1, Int(CGFloat(cg.height) * f))

        var raw = [UInt8](repeating: 0, count: w * h * 4)
        var ok = false

        raw.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(
                      data: base, width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            ok = true
        }
        guard ok else { throw ForgeError.renderFailed }

        var out = [SIMD3<Float>]()
        out.reserveCapacity(w * h)
        for i in stride(from: 0, to: raw.count, by: 4) {
            out.append(SIMD3(Float(raw[i]) / 255,
                             Float(raw[i + 1]) / 255,
                             Float(raw[i + 2]) / 255))
        }
        return (out, w, h)
    }

    /// k-means++: centros iniciales separados, no aleatorios puros.
    private static func seed(_ pts: [SIMD3<Float>], k: Int) -> [SIMD3<Float>] {
        var centers = [pts[pts.count / 2]]
        let stride = max(1, pts.count / 2000)
        while centers.count < k {
            var best = pts[0]
            var bestD: Float = -1
            var i = 0
            while i < pts.count {
                let p = pts[i]
                var nearest = Float.greatestFiniteMagnitude
                for c in centers {
                    nearest = min(nearest, dist(p, c))
                }
                if nearest > bestD { bestD = nearest; best = p }
                i += stride
            }
            centers.append(best)
        }
        return centers
    }

    private static func buildMask(assign: [Int], target: Int,
                                  width: Int, height: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for i in assign.indices where assign[i] == target {
            bytes[i] = 255
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

    private static func dist(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return d.x * d.x + d.y * d.y + d.z * d.z
    }

    /// sRGB -> CIE Lab. Distancias perceptuales, no aritméticas.
    private static func rgbToLab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        func lin(_ v: Float) -> Float {
            v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
        }
        let r = lin(c.x), g = lin(c.y), b = lin(c.z)
        let x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047
        let y =  r * 0.2126 + g * 0.7152 + b * 0.0722
        let z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883

        func f(_ t: Float) -> Float {
            t > 0.008856 ? powf(t, 1.0 / 3.0) : (7.787 * t) + 16.0 / 116.0
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
