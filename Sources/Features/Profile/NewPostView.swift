import SwiftUI

/// Экран создания записи: текст + фото + граффити.
struct NewPostView: View {
    let ownerID: Int
    var onPosted: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = NewPostViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showPhotoPicker = false
    @State private var showGraffiti = false

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                textEditor
                if !model.images.isEmpty { attachments }
                addBar
                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundColor(.red).padding(.horizontal)
                }
                Spacer()
            }
            .background(OVK.Palette.card.ignoresSafeArea())
            .navigationTitle("Новая запись")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if model.isPosting {
                        ProgressView()
                    } else {
                        Button("Опубликовать") {
                            Task {
                                if await model.publish(ownerID: ownerID, settings: settings) {
                                    onPosted()
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!model.canPost)
                    }
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPicker { model.addImage($0) }
            }
            .fullScreenCover(isPresented: $showGraffiti) {
                GraffitiView { model.addImage($0) }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var textEditor: some View {
        ZStack(alignment: .topLeading) {
            if model.text.isEmpty {
                Text("Что у вас нового?")
                    .foregroundColor(OVK.Palette.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
            TextEditor(text: $model.text)
                .padding(12)
                .frame(minHeight: 140)
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.images.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image)
                            .resizable().scaledToFill()
                            .frame(width: 90, height: 90)
                            .clipped().cornerRadius(6)
                        Button { model.removeImage(at: index) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                        }
                        .padding(4)
                    }
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 100)
    }

    private var addBar: some View {
        HStack(spacing: 24) {
            Button { showPhotoPicker = true } label: {
                Label("Фото", systemImage: "photo")
            }
            Button { showGraffiti = true } label: {
                Label("Граффити", systemImage: "scribble.variable")
            }
            Spacer()
        }
        .foregroundColor(OVK.Palette.primary)
        .padding()
    }
}
