import SwiftUI
import UIKit

/// Лёгкое молочно-белое стекло в стиле экрана нового плеера.
/// Не меняет effect при обновлениях SwiftUI — это важно для плавности прокрутки.
struct LightGlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if reduceTransparency || contrast == .increased {
            Color.white
        } else {
            LightGlassEffect()
        }
    }
}

private struct LightGlassEffect: UIViewRepresentable {
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

extension View {
    /// Единая строка записи для ленты и стен: белая плоскость, тонкие границы и
    /// узкий серый интервал. Контент PostRow остаётся одинаковым во всех местах.
    func ovkPostListRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(OVK.Palette.card)
            .overlay(OVKHairline(), alignment: .top)
            .overlay(OVKHairline(), alignment: .bottom)
            .padding(.bottom, OVK.Metrics.compactCornerRadius)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(OVK.Palette.background)
    }
}

/// Компактный сегментированный переключатель эпохи iOS 7: тонкая синяя рамка,
/// синий выбранный сегмент и неизменная геометрия на всех поддерживаемых iOS.
struct OVKSegmentedControl<Selection: Hashable>: View {
    let options: [(value: Selection, title: String)]
    @Binding var selection: Selection
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { index in
                    if index > options.startIndex {
                        OVK.Palette.primary
                            .frame(width: 1 / displayScale, height: 30)
                    }
                    visualSegment(options[index])
                }
            }
            .frame(height: 30)
            .clipShape(RoundedRectangle(cornerRadius: OVK.Metrics.compactCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: OVK.Metrics.compactCornerRadius)
                    .stroke(OVK.Palette.primary, lineWidth: 1 / displayScale)
            }

            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    Button { selection = option.value } label: {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                }
            }
        }
        .frame(height: OVK.Metrics.minimumTapSize)
        .padding(.horizontal, OVK.Metrics.contentInset)
        .background(OVK.Palette.card.overlay(OVKHairline(), alignment: .bottom))
    }

    private func visualSegment(_ option: (value: Selection, title: String)) -> some View {
        let selected = selection == option.value
        return Text(option.title)
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(selected ? .white : OVK.Palette.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? OVK.Palette.primary : OVK.Palette.card)
            .accessibilityHidden(true)
    }
}

/// Постоянная строка поиска под навбаром. В отличие от `.searchable`, не принимает
/// современную форму/отступы текущей версии iOS и не прыгает между состояниями скролла.
struct OVKSearchStrip: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var isFocused: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: OVK.Metrics.controlCornerRadius)
                .fill(OVK.Palette.background)
                .frame(height: 32)
                .overlay {
                    RoundedRectangle(cornerRadius: OVK.Metrics.controlCornerRadius)
                        .stroke(OVK.Palette.separator, lineWidth: 1 / displayScale)
                        .frame(height: 32)
                }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(OVK.Palette.textSecondary)
                    .accessibilityHidden(true)

                TextField(prompt, text: $text)
                    .font(.subheadline)
                    .foregroundColor(OVK.Palette.textPrimary)
                    .focused($isFocused)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.search)
                    .onSubmit { isFocused = false }

                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(OVK.Palette.textSecondary.opacity(0.7))
                            .frame(width: OVK.Metrics.minimumTapSize,
                                   height: OVK.Metrics.minimumTapSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Очистить поиск")
                }
            }
            .padding(.leading, 9)
        }
        .padding(.horizontal, 8)
        .frame(height: OVK.Metrics.minimumTapSize)
        .background(OVK.Palette.card.overlay(OVKHairline(), alignment: .bottom))
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
