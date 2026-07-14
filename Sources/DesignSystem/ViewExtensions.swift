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

