import Foundation
import UIKit

/// Límites que dependen del proceso y del dispositivo.
/// Una extensión tiene un presupuesto de memoria mucho menor que la app.
enum ForgeEnvironment {

    /// Una app extension vive en un bundle .appex.
    static let isExtension: Bool = Bundle.main.bundlePath.hasSuffix(".appex")

    /// Memoria física, en bytes.
    static let physicalMemory = ProcessInfo.processInfo.physicalMemory

    /// Píxeles máximos de salida.
    ///
    /// Un bitmap RGBA de N píxeles ocupa 4N bytes, y Core Image necesita
    /// al menos un intermedio más. Se reserva una fracción conservadora de
    /// la RAM física y se recorta a un techo absoluto.
    static var maxOutputPixels: Int {
        if isExtension { return 6_000_000 }

        // Un bitmap RGBA ocupa 4 bytes por píxel. Se reserva una
        // dieciseisava parte de la RAM física para él, lo que en un
        // teléfono de 6 GB da unos 100 MP, y se recorta a 64 MP:
        // 256 MB de bitmap, que iOS concede sin matar el proceso.
        let budget = Int(physicalMemory / 4) / 16
        return min(64_000_000, max(6_000_000, budget))
    }

    /// Escala máxima que cabe para una imagen de este tamaño.
    /// Sirve para limitar el deslizador en vez de dejar que el usuario
    /// elija un valor que va a fallar.
    static func maxScale(forPixels pixels: Int) -> Double {
        guard pixels > 0 else { return 8 }
        let limit = (Double(maxOutputPixels) / Double(pixels)).squareRoot()
        // Se redondea hacia abajo al paso de 0.5 del deslizador.
        let stepped = (limit * 2).rounded(.down) / 2
        return min(8, max(1, stepped))
    }

    /// Baldosa de inferencia para el modelo neural.
    /// El modelo se convirtió a 512; en la extensión se rechaza la ruta
    /// neural entera, así que este valor solo aplica a la app.
    static let neuralTile = 512

    /// La extensión nunca usa el motor neural: no cabe en su presupuesto.
    static var allowsNeural: Bool { !isExtension }
}
