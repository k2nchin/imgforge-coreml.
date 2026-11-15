import Foundation

enum ForgeError: LocalizedError {
    case noImage
    case decodeFailed
    case tooLarge(pixels: Int, limit: Int)
    case filterFailed(String)
    case renderFailed
    case visionFailed(String)
    case noContours
    case encodeFailed
    case writeFailed(String)
    case modelMissing(String)
    case modelLoadFailed(String)
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .noImage:
            return "No hay imagen cargada."
        case .decodeFailed:
            return "No se pudo decodificar la imagen."
        case .tooLarge(let p, let l):
            return "Salida demasiado grande: \(p) px (límite \(l)). Baja la escala."
        case .filterFailed(let n):
            return "El filtro \(n) no produjo salida."
        case .renderFailed:
            return "Fallo al renderizar el resultado."
        case .visionFailed(let m):
            return "Vision falló: \(m)"
        case .noContours:
            return "No se detectaron contornos. Usa una imagen con más contraste."
        case .encodeFailed:
            return "Fallo al codificar PNG."
        case .writeFailed(let m):
            return "Fallo al escribir el archivo: \(m)"
        case .modelMissing(let n):
            return "Falta \(n).mlmodelc en el bundle. Usa el motor clásico."
        case .modelLoadFailed(let m):
            return "No se pudo cargar el modelo: \(m)"
        case .inferenceFailed(let m):
            return "La inferencia falló: \(m)"
        }
    }
}
