import SwiftUI

/// Экран комментариев к записи: список + панель ввода (текст + фото).
struct CommentsView: View {
    let ownerID: Int
    let postID: Int

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = CommentsViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showPhotoPicker = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                list
                if !model.images.isEmpty { pendingThumbs }
                inputBar
            }
            .background(OVK.Palette.background.ignoresSafeArea())
            .navigationTitle("Комментарии")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPicker { model.images.append($0) }
            }
            .handlesOVKLinks() // ссылки в комментариях тоже открываются в приложении
            .task { await model.load(ownerID: ownerID, postID: postID, settings: settings) }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var list: some View {
        if model.isLoading && model.comments.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.comments.isEmpty {
            Text("Пока нет комментариев")
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.comments) { comment in
                        CommentRow(
                            comment: comment,
                            author: model.authors[comment.fromID],
                            ownerID: ownerID,
                            onReply: {
                                model.prefillReply(to: comment.fromID, name: model.authors[comment.fromID]?.name)
                                inputFocused = true
                            }
                        )
                            .background(OVK.Palette.card)
                            // can_delete у OpenVK для коммента считается по посту, поэтому
                            // ещё разрешаем удалять СВОИ комментарии (from_id == мой id).
                            .conditionalContextMenu(comment.canDelete || comment.fromID == (settings.userID ?? Int.min)) {
                                Button(role: .destructive) {
                                    Task { await model.delete(comment, settings: settings) }
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pendingThumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.images.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image)
                            .resizable().scaledToFill()
                            .frame(width: 64, height: 64).clipped().cornerRadius(6)
                        Button { model.images.remove(at: index) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                        }
                        .padding(2)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 74)
        .background(OVK.Palette.card)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button { showPhotoPicker = true } label: {
                Image(systemName: "photo").foregroundColor(OVK.Palette.primary)
            }
            TextField("Комментарий…", text: $model.text)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
            if model.isSending {
                ProgressView()
            } else {
                Button {
                    Task { await model.send(ownerID: ownerID, postID: postID, settings: settings) }
                } label: {
                    Image(systemName: "paperplane.fill").foregroundColor(OVK.Palette.primary)
                }
                .disabled(!model.canSend)
            }
        }
        .padding(8)
        .background(OVK.Palette.card)
    }
}

