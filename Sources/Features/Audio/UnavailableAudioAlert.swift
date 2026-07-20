import SwiftUI

/// Диалог в стилистике VK для треков, которые сервер не отдаёт приложению.
struct UnavailableAudioAlert: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        ZStack {
            content
            if isPresented {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                VStack(spacing: 20) {
                    HStack {
                        Spacer()
                        Button(action: dismiss) {
                            Image(systemName: "xmark")
                                .font(.headline.weight(.bold))
                                .foregroundColor(OVK.Palette.textSecondary)
                                .frame(width: 42, height: 42)
                                .background(Circle().fill(OVK.Palette.background))
                        }
                    }
                    .padding(.bottom, -28)

                    Text("😔")
                        .font(.system(size: 76))
                    Text("Аудиозапись недоступна")
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Сервер не разрешает воспроизводить эту аудиозапись в приложении.")
                        .font(.body)
                        .foregroundColor(OVK.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .frame(maxWidth: 330)
                .background(OVK.Palette.card)
                .cornerRadius(28)
                .padding(24)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isPresented)
    }

    private func dismiss() {
        isPresented = false
        onDismiss()
    }
}

extension View {
    func unavailableAudioAlert(isPresented: Binding<Bool>, onDismiss: @escaping () -> Void) -> some View {
        modifier(UnavailableAudioAlert(isPresented: isPresented, onDismiss: onDismiss))
    }
}
