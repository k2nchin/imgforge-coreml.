import SwiftUI

/// Marco de recorte con esquinas arrastrables, rejilla de tercios y
/// proporciones fijas. El rectángulo viaja normalizado (0–1) con origen
/// arriba-izquierda, igual que lo espera `Adjustments.apply`.
struct CropOverlay: View {
    let image: UIImage
    @Binding var rect: CGRect
    var ratio: CGFloat?          // nil = libre

    @State private var dragStart: CGRect?

    private let handle: CGFloat = 28
    private let minSide: CGFloat = 0.08

    var body: some View {
        GeometryReader { geo in
            let frame = fittedFrame(in: geo.size)
            let r = CGRect(x: frame.minX + rect.minX * frame.width,
                           y: frame.minY + rect.minY * frame.height,
                           width: rect.width * frame.width,
                           height: rect.height * frame.height)

            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()

                Canvas { ctx, size in
                    // Todo lo que queda fuera del marco se oscurece.
                    var outside = Path(CGRect(origin: .zero, size: size))
                    outside.addRect(r)
                    ctx.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))

                    ctx.stroke(Path(r), with: .color(.white), lineWidth: 1.5)

                    // Tercios.
                    var grid = Path()
                    for i in 1...2 {
                        let x = r.minX + r.width * CGFloat(i) / 3
                        let y = r.minY + r.height * CGFloat(i) / 3
                        grid.move(to: CGPoint(x: x, y: r.minY))
                        grid.addLine(to: CGPoint(x: x, y: r.maxY))
                        grid.move(to: CGPoint(x: r.minX, y: y))
                        grid.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                    ctx.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 0.8)

                    // Esquinas.
                    for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                              CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
                        let box = CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)
                        ctx.fill(Path(ellipseIn: box), with: .color(.white))
                    }
                }
                .allowsHitTesting(false)

                // Zonas de arrastre: una por esquina, más el centro.
                ForEach(Corner.allCases) { corner in
                    Color.clear
                        .frame(width: handle, height: handle)
                        .contentShape(Rectangle())
                        .position(corner.point(in: r))
                        .gesture(dragGesture(corner: corner, frame: frame))
                        .accessibilityHidden(true)
                }

                Color.clear
                    .frame(width: max(0, r.width - handle), height: max(0, r.height - handle))
                    .contentShape(Rectangle())
                    .position(x: r.midX, y: r.midY)
                    .gesture(dragGesture(corner: nil, frame: frame))
            }
            .accessibilityElement()
            .accessibilityLabel("Marco de recorte")
            .accessibilityValue("\(Int(rect.width * 100)) por \(Int(rect.height * 100)) por ciento")
        }
    }

    // MARK: - Arrastre

    private enum Corner: String, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: String { rawValue }

        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft:     return CGPoint(x: r.minX, y: r.minY)
            case .topRight:    return CGPoint(x: r.maxX, y: r.minY)
            case .bottomLeft:  return CGPoint(x: r.minX, y: r.maxY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }
    }

    private func dragGesture(corner: Corner?, frame: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? rect
                if dragStart == nil { dragStart = rect }

                let dx = value.translation.width / frame.width
                let dy = value.translation.height / frame.height

                var new = start
                if let corner {
                    switch corner {
                    case .topLeft:
                        new.origin.x += dx; new.origin.y += dy
                        new.size.width -= dx; new.size.height -= dy
                    case .topRight:
                        new.origin.y += dy
                        new.size.width += dx; new.size.height -= dy
                    case .bottomLeft:
                        new.origin.x += dx
                        new.size.width -= dx; new.size.height += dy
                    case .bottomRight:
                        new.size.width += dx; new.size.height += dy
                    }
                    new = applyRatio(new, anchor: corner, frame: frame)
                } else {
                    new.origin.x += dx
                    new.origin.y += dy
                }
                rect = clamp(new)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Con proporción fija, la altura se deduce del ancho y se ancla en la
    /// esquina contraria a la que se arrastra.
    private func applyRatio(_ r: CGRect, anchor: Corner, frame: CGRect) -> CGRect {
        guard let ratio else { return r }
        var new = r

        let pixelWidth = r.width * frame.width
        let pixelHeight = pixelWidth / ratio
        new.size.height = pixelHeight / frame.height

        switch anchor {
        case .topLeft, .topRight:
            new.origin.y = r.maxY - new.height
        case .bottomLeft, .bottomRight:
            new.origin.y = r.minY
        }
        return new
    }

    private func clamp(_ r: CGRect) -> CGRect {
        var new = r
        new.size.width = min(1, max(minSide, new.width))
        new.size.height = min(1, max(minSide, new.height))
        new.origin.x = min(1 - new.width, max(0, new.minX))
        new.origin.y = min(1 - new.height, max(0, new.minY))
        return new
    }

    /// Dónde cae la imagen dentro del contenedor con `scaledToFit`.
    private func fittedFrame(in size: CGSize) -> CGRect {
        let aspect = image.size.width / max(image.size.height, 1)
        var w = size.width
        var h = w / aspect
        if h > size.height {
            h = size.height
            w = h * aspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}
