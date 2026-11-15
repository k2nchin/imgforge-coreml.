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
        if isExtension { return 4_000_000 }          // ~16 MB de bitmap

        // Una octava parte de la RAM, dividida entre 4 bytes por píxel
        // y 2 buffers simultáneos.
        let budget = Int(physicalMemory / 8) / 8
        return min(24_000_000, max(4_000_000, budget))
    }

    /// Baldosa de inferencia para el modelo neural.
    /// El modelo se convirtió a 512; en la extensión se rechaza la ruta
    /// neural entera, así que este valor solo aplica a la app.
    static let neuralTile = 512

    /// La extensión nunca usa el motor neural: no cabe en su presupuesto.
    static var allowsNeural: Bool { !isExtension }
}
