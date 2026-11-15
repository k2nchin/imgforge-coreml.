import SwiftUI

/// Visor a pantalla completa.
///
/// Dentro del ScrollView de la pantalla principal, el arrastre se lo
/// queda el scroll y el zoom queda a medias. Aquí no hay scroll que
/// compita, así que el pinch y el paneo funcionan limpios y la imagen
/// ocupa todo el teléfono.
struct FullscreenPreview: View {
    let before: UIImage?
    let after: UIImage?
    @Binding var splitEnabled: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ZoomableImageView(before: before, after: after,
                              splitEnabled: $splitEnabled)
                .ignoresSafeArea(edges: .bottom)

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Cerrar")

                    Spacer()

                    if before != nil && after != nil {
                        Button {
                            splitEnabled.toggle()
                        } label: {
                            Image(systemName: splitEnabled
                                  ? "rectangle.lefthalf.inset.filled"
                                  : "rectangle")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel(splitEnabled
                                            ? "Ocultar comparación"
                                            : "Comparar antes y después")
                    }
                }
                .padding(.horizontal, 16)

                Spacer()

                Text("Pellizca para ampliar · Doble toque para 3×")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.bottom, 24)
            }
        }
        .statusBarHidden()
    }
}
