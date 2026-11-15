import SwiftUI

struct PresetBar: View {
    let presets: [Preset]
    let onPick: (Preset) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets) { p in
                    Button { onPick(p) } label: {
                        Label(p.name, systemImage: p.symbol)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SharedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

extension Binding where Value == CGFloat {
    var asDouble: Binding<Double> {
        Binding<Double>(get: { Double(wrappedValue) },
                        set: { wrappedValue = CGFloat($0) })
    }
}

extension Binding where Value == Float {
    var asDouble: Binding<Double> {
        Binding<Double>(get: { Double(wrappedValue) },
                        set: { wrappedValue = Float($0) })
    }
}
