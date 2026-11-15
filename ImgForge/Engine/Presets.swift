import Foundation

struct Preset: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let kind: Kind

    enum Kind: Hashable {
        case upscale(Upscaler.Options)
        case vector(Vectorizer.Options)
    }

    static let all: [Preset] = [
        Preset(id: "logo_vector", name: "Logo a vector", symbol: "scribble.variable",
               kind: .vector(Vectorizer.Options(
                   simplify: 0.0015, minArea: 0.0008,
                   colorMode: .mono, curves: true))),

        Preset(id: "art_color", name: "Arte a color", symbol: "paintpalette",
               kind: .vector(Vectorizer.Options(
                   simplify: 0.0025, minArea: 0.0004,
                   colorMode: .palette(8), curves: true))),

        Preset(id: "photo_2x", name: "Foto 2× nítida", symbol: "photo",
               kind: .upscale(Upscaler.Options(
                   scale: 2, method: .lanczos, sharpen: 0.55,
                   noiseReduction: true, engine: .auto))),

        Preset(id: "shot_4x", name: "Screenshot 4×", symbol: "rectangle.on.rectangle",
               kind: .upscale(Upscaler.Options(
                   scale: 4, method: .lanczos, sharpen: 0.25,
                   noiseReduction: false, engine: .classic))),

        Preset(id: "ai_max", name: "Máxima calidad", symbol: "sparkles",
               kind: .upscale(Upscaler.Options(
                   scale: 4, method: .lanczos, sharpen: 0.0,
                   noiseReduction: false, engine: .neural)))
    ]
}
