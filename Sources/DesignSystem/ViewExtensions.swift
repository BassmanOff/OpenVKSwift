import SwiftUI
import UIKit

/// Лёгкое молочно-белое стекло в стиле экрана нового плеера.
/// Не меняет effect при обновлениях SwiftUI — это важно для плавности прокрутки.
struct LightGlassBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: .extraLight))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

/// Единый разделитель толщиной в один физический пиксель.
struct OVKHairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        OVK.Palette.separator
            .frame(height: 1 / displayScale)
    }
}

/// Небольшая вьюха «ошибка + повторить» (переиспользуется в списках).
struct ErrorRetry: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .foregroundColor(OVK.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Повторить", action: retry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
