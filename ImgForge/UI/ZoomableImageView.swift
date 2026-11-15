import SwiftUI

/// Visor con pinch, pan, doble tap al 300% y cortina antes/después.
struct ZoomableImageView: View {
    let before: UIImage?
    let after: UIImage?
    @Binding var splitEnabled: Bool

    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var split: CGFloat = 0.5

    private let maxZoom: CGFloat = 12

    /// La cortina se apaga al ampliar: la máscara escala con la imagen y
    /// el tirador no, así que lo que se ve y lo que se arrastra dejarían
    /// de coincidir.
    private var showsSplit: Bool {
        splitEnabled && before != nil && after != nil && zoom <= 1.02
    }

    /// Rectángulo que ocupa la imagen dentro del contenedor con scaledToFit.
    private func fitted(in size: CGSize) -> CGRect {
        let img = after ?? before
        guard let img, img.size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let aspect = img.size.width / img.size.height
        var w = size.width
        var h = w / aspect
        if h > size.height {
            h = size.height
            w = h * aspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2,
                      width: w, height: h)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.secondarySystemGroupedBackground)

                content(in: geo.size)
                    .scaleEffect(zoom)
                    .offset(offset)
                    .gesture(magnify.simultaneously(with: drag))
                    .onTapGesture(count: 2) { toggleZoom() }

                if showsSplit {
                    handle(in: geo.size)
                }

                if zoom > 1.02 {
                    zoomBadge
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(showsSplit ? "Comparación antes y después" : "Vista previa")
            .accessibilityValue(showsSplit
                ? "Cortina al \(Int(split * 100)) por ciento"
                : "Zoom \(String(format: "%.1f", zoom)) aumentos")
            .accessibilityAdjustableAction { direction in
                if showsSplit {
                    split = min(1, max(0, split + (direction == .increment ? 0.08 : -0.08)))
                } else {
                    setZoom(zoom * (direction == .increment ? 1.5 : 0.667))
                    lastZoom = zoom
                }
            }
        }
    }

    // MARK: - Contenido

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        ZStack {
            if let before {
                Image(uiImage: before)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
            if let after {
                Image(uiImage: after)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .mask(alignment: .leading) {
                        if showsSplit {
                            // El corte se mide sobre la imagen, no sobre el
                            // contenedor: con bandas laterales no coinciden.
                            let box = fitted(in: size)
                            Rectangle()
                                .frame(width: box.minX + box.width * split)
                        } else {
                            Rectangle()
                        }
                    }
            }
        }
    }

    private func handle(in size: CGSize) -> some View {
        let box = fitted(in: size)
        let x = box.minX + box.width * split

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.white)
                .frame(width: 2)
                .shadow(color: .black.opacity(0.35), radius: 3)
                .position(x: x, y: size.height / 2)

            Circle()
                .fill(.white)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.28), radius: 5, y: 1)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                }
                .position(x: x, y: size.height / 2)

            label("ANTES", at: .leading)
            label("DESPUÉS", at: .trailing)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let box = fitted(in: size)
                    guard box.width > 0 else { return }
                    split = min(1, max(0, (g.location.x - box.minX) / box.width))
                }
        )
    }

    private func label(_ text: String, at edge: Alignment) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge)
            .padding(10)
            .allowsHitTesting(false)
    }

    private var zoomBadge: some View {
        Text(String(format: "%.1f×", zoom))
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(10)
            .allowsHitTesting(false)
    }

    // MARK: - Gestos

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in setZoom(lastZoom * v.magnification) }
            .onEnded { _ in
                lastZoom = zoom
                if zoom <= 1.02 { resetPan() }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { v in
                guard zoom > 1.02 else { return }
                offset = CGSize(width: lastOffset.width + v.translation.width,
                                height: lastOffset.height + v.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(maxZoom, max(1, value))
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            if zoom > 1.02 {
                zoom = 1
                lastZoom = 1
                resetPan()
            } else {
                zoom = 3
                lastZoom = 3
            }
        }
    }

    private func resetPan() {
        offset = .zero
        lastOffset = .zero
    }
}
