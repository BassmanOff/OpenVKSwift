import SwiftUI
import UIKit

/// Многострочное поле, растущее по высоте под текст — как в Заметках/Напоминаниях.
/// SwiftUI TextEditor на iOS 15 не считает интринсик-высоту (и без клиппинга вылезает за
/// границы строки Form, перекрывая соседние поля). Поэтому оборачиваем UITextView со
/// scrollEnabled=false: он сам отдаёт intrinsicContentSize и растёт вместе с контентом,
/// а Form подстраивает высоту ячейки штатно.
struct GrowingTextEditor: View {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 36
    /// Выше этой высоты поле перестаёт расти и скроллится само (как composer в ЛС).
    var maxHeight: CGFloat = .greatestFiniteMagnitude
    /// Дёргается, когда высота реально изменилась — чтобы вызывающая сторона подскроллила
    /// экран вслед за растущим полем (курсор не должен уезжать под клавиатуру).
    var onGrow: () -> Void = {}

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder)
                    .foregroundColor(OVK.Palette.textSecondary)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            AutoSizingTextView(text: $text, maxHeight: maxHeight, onHeightChange: onGrow)
        }
        .frame(minHeight: minHeight, alignment: .topLeading)
    }
}

/// Растёт по контенту через intrinsicContentSize — переиспользует ту же логику, что и
/// composer в ЛС (SelfSizingTextView из ChatScreenController), включая cap+внутренний скролл.
private struct AutoSizingTextView: UIViewRepresentable {
    @Binding var text: String
    var maxHeight: CGFloat
    var onHeightChange: () -> Void

    func makeUIView(context: Context) -> SelfSizingTextView {
        let tv = SelfSizingTextView()
        tv.maxHeight = maxHeight
        tv.backgroundColor = .clear
        tv.font = .preferredFont(forTextStyle: .body)
        // Инсеты обнуляем по бокам, чтобы текст встал вровень с обычными TextField в Form.
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.delegate = context.coordinator
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        // Иначе UITextView с низким hugging растягивается на всё свободное место в HStack
        // (панель ввода комментариев занимала треть экрана). С required — жмётся к контенту
        // и растёт только по тексту (до maxHeight).
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: SelfSizingTextView, context: Context) {
        context.coordinator.parent = self          // держим биндинг/колбэк свежими
        tv.maxHeight = maxHeight
        if tv.text != text { tv.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AutoSizingTextView
        private var lastHeight: CGFloat = 0
        init(_ parent: AutoSizingTextView) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            tv.invalidateIntrinsicContentSize()
            let h = tv.intrinsicContentSize.height
            guard abs(h - lastHeight) > 0.5 else { return }
            lastHeight = h
            parent.onHeightChange()
        }
    }
}
