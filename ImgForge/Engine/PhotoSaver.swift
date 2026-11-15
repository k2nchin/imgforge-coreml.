import Photos
import UIKit

/// Guarda resultados en el carrete. Solo pide permiso de escritura (`.addOnly`),
/// que no da acceso de lectura a la biblioteca del usuario.
enum PhotoSaver {

    enum Outcome {
        case saved(Int)
        case denied
        case failed(String)

        var message: String {
            switch self {
            case .saved(let n):
                return n == 1 ? "Guardado en Fotos." : "\(n) archivos guardados en Fotos."
            case .denied:
                return "Permiso denegado. Actívalo en Ajustes › Privacidad › Fotos."
            case .failed(let m):
                return "No se pudo guardar: \(m)"
            }
        }
    }

    /// Solo imágenes: un SVG no es un asset válido para el carrete.
    static func save(urls: [URL]) async -> Outcome {
        let allowed: Set<String> = ["png", "jpg", "jpeg", "heic"]
        let images = urls.filter { allowed.contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else {
            return .failed("Fotos solo acepta imágenes. Para SVG o PDF, usa Compartir.")
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                for url in images {
                    PHAssetCreationRequest.forAsset()
                        .addResource(with: .photo, fileURL: url, options: nil)
                }
            }
            return .saved(images.count)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
