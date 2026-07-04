import SwiftUI

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

extension View {
    /// Прикрепляет контекст-меню только когда `enabled` (иначе пустого меню на long-press не будет).
    @ViewBuilder
    func conditionalContextMenu<M: View>(_ enabled: Bool, @ViewBuilder menuItems: () -> M) -> some View {
        if enabled {
            self.contextMenu { menuItems() }
        } else {
            self
        }
    }
}
