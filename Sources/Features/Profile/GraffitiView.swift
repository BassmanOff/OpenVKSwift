import SwiftUI
import PencilKit

/// Простое граффити: рисуем пальцем на белом холсте, экспортируем в картинку.
struct GraffitiView: View {
    var onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var canvas = PKCanvasView()
    @State private var color: Color = .black

    private let palette: [Color] = [.black, OVK.Palette.primary, .red, .green, .orange, .purple]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                GraffitiCanvas(canvas: canvas, color: UIColor(color))
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
                        .disabled(canvas.drawing.strokes.isEmpty)
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

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput          // рисуем и пальцем
        canvas.backgroundColor = .white
        canvas.tool = PKInkingTool(.pen, color: color, width: 6)
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.tool = PKInkingTool(.pen, color: color, width: 6)
    }
}
