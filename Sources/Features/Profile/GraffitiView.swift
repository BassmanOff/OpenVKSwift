import SwiftUI
import PencilKit

/// Простое граффити: рисуем пальцем на белом холсте, экспортируем в картинку.
struct GraffitiView: View {
    var onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var canvas = PKCanvasView()
    @State private var color: Color = .black
    /// PKCanvasView — UIKit, SwiftUI не наблюдает canvas.drawing напрямую (кнопка «Готово»
    /// оставалась disabled после рисования, пока что-то ещё не форсировало re-render).
    @State private var hasStrokes = false

    private let palette: [Color] = [.black, OVK.Palette.primary, .red, .green, .orange, .purple]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                GraffitiCanvas(canvas: canvas, color: UIColor(color), hasStrokes: $hasStrokes)
                    .background(Color.white)

                HStack(spacing: 16) {
                    ForEach(palette, id: \.self) { c in
                        Circle()
                            .fill(c)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.gray.opacity(color == c ? 0.9 : 0.2), lineWidth: 2))
                            .onTapGesture { color = c }
                    }
                    Spacer()
                    Button {
                        canvas.drawing = PKDrawing()
                        hasStrokes = false
                    } label: {
                        Image(systemName: "trash").foregroundColor(OVK.Palette.textSecondary)
                    }
                }
                .padding()
                .background(OVK.Palette.background)
            }
            .navigationTitle("Граффити")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { export() }
                        .disabled(!hasStrokes)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func export() {
        let bounds = canvas.bounds
        guard bounds.width > 0, bounds.height > 0 else { dismiss(); return }
        let drawingImage = canvas.drawing.image(from: bounds, scale: UIScreen.main.scale)
        // Кладём рисунок на белый фон (drawing.image прозрачный).
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let composed = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(bounds)
            drawingImage.draw(in: bounds)
        }
        onDone(composed)
        dismiss()
    }
}

private struct GraffitiCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    let color: UIColor
    @Binding var hasStrokes: Bool

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput          // рисуем и пальцем
        canvas.backgroundColor = .white
        canvas.tool = PKInkingTool(.pen, color: color, width: 6)
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.tool = PKInkingTool(.pen, color: color, width: 6)
    }

    func makeCoordinator() -> Coordinator { Coordinator(hasStrokes: $hasStrokes) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var hasStrokes: Bool
        init(hasStrokes: Binding<Bool>) { self._hasStrokes = hasStrokes }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            hasStrokes = !canvasView.drawing.strokes.isEmpty
        }
    }
}
