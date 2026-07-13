import SwiftUI

/// Экран комментариев к записи: пост (если передан) + список комментариев + панель ввода (текст + фото).
struct CommentsView: View {
    let ownerID: Int
    let postID: Int
    let fallbackIDs: [Int]
    /// Пост для отображения в шапке. Если не передан — загружается через wall.getById.
    var post: Post? = nil

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var likes: LikesManager
    @EnvironmentObject private var photoHero: PhotoHeroCoordinator
    @StateObject private var model = CommentsViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showPhotoPicker = false
    @State private var showAudioPicker = false
    @State private var showVideoPicker = false
    @State private var showDocPicker = false
    @FocusState private var inputFocused: Bool
    /// Меню вложений — через confirmationDialog, НЕ через Menu: встроенное UIKit-меню
    /// рядом с TextField ломало на iOS 15 расчёт keyboard-avoidance (панель ввода
    /// зависала посреди экрана с белым блоком под ней до следующей перерисовки).
    @State private var showAttachMenu = false

    /// Пост для отображения: переданный напрямую или загруженный ViewModel'ом.
    private var displayPost: Post? {
        post ?? model.post
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                list
                if !model.images.isEmpty { pendingThumbs }
                if !model.audioTracks.isEmpty { pendingAudio }
                if !model.videos.isEmpty { pendingVideo }
                if !model.docs.isEmpty { pendingDocs }
                if let groupName = model.adminGroupName { identityBar(groupName) }
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
                PhotoPicker { model.addImage($0) }
            }
            .sheet(isPresented: $showAudioPicker) {
                AudioAttachPicker { model.addAudio($0) }
            }
            .sheet(isPresented: $showVideoPicker) {
                VideoAttachPicker { model.addVideo($0) }
            }
            .sheet(isPresented: $showDocPicker) {
                DocAttachPicker { model.addDoc($0) }
            }
            .handlesOVKLinks() // ссылки в комментариях тоже открываются в приложении
            .task {
                if let post = post {
                    model.setPost(post)
                    await model.loadPostAuthors(settings: settings)
                }
                await model.loadWithFallbacks(ownerID: ownerID, postID: postID, fallbackIDs: fallbackIDs, settings: settings)
                if displayPost == nil {
                    await model.loadPost(ownerID: ownerID, postID: postID, settings: settings)
                    await model.loadPostAuthors(settings: settings)
                }
                await model.loadGroupIdentity(ownerID: ownerID, settings: settings)
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var list: some View {
        if model.isLoading && model.comments.isEmpty && displayPost == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.comments.isEmpty && displayPost == nil {
            Text("Пока нет комментариев")
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let displayPost = displayPost {
                        PostRow(post: displayPost, authors: model.authors, commentTapEnabled: false)
                            .background(OVK.Palette.card)
                        Divider()
                    }
                    ForEach(model.comments) { comment in
                        // Скорректированный id автора (отрицательный для групп-авторов,
                        // в т.ч. для on-behalf, которые сервер вернул как DELETED-стаб в profiles).
                        let authorID = model.effectiveAuthorID(comment)
                        CommentRow(
                            comment: comment,
                            author: model.authors[authorID],
                            authorID: authorID,
                            ownerID: ownerID,
                            onReply: {
                                model.prefillReply(to: authorID, name: model.authors[authorID]?.name)
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

    private var pendingAudio: some View {
        VStack(spacing: 4) {
            ForEach(Array(model.audioTracks.enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 6) {
                    Image(systemName: "music.note").font(.caption).foregroundColor(OVK.Palette.primary)
                    Text("\(track.artist) — \(track.title)")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button { model.removeAudio(at: index) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(OVK.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 4)
        .background(OVK.Palette.card)
    }

    private var pendingVideo: some View {
        VStack(spacing: 4) {
            ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                HStack(spacing: 6) {
                    Image(systemName: "video").font(.caption).foregroundColor(OVK.Palette.primary)
                    Text(video.title).font(.caption).lineLimit(1)
                    Spacer()
                    Button { model.removeVideo(at: index) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(OVK.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 4)
        .background(OVK.Palette.card)
    }

    private var pendingDocs: some View {
        VStack(spacing: 4) {
            ForEach(Array(model.docs.enumerated()), id: \.element.id) { index, doc in
                HStack(spacing: 6) {
                    Image(systemName: "doc").font(.caption).foregroundColor(OVK.Palette.primary)
                    Text(doc.title).font(.caption).lineLimit(1)
                    Text(doc.sizeText).font(.caption2).foregroundColor(OVK.Palette.textSecondary)
                    Spacer()
                    Button { model.removeDoc(at: index) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(OVK.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 4)
        .background(OVK.Palette.card)
    }

    private func identityBar(_ groupName: String) -> some View {
        Toggle("Комментировать от имени «\(groupName)»", isOn: $model.commentAsGroup)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(OVK.Palette.card)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Как в ЛС (ChatScreenController.attachButton) — одна скрепка вместо
            // отдельной кнопки на каждый тип вложения, чтобы не раздувать панель ввода.
            Button { showAttachMenu = true } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 22))
                    .foregroundColor(OVK.Palette.primary)
                    .frame(width: 38, height: 38)
            }
            .confirmationDialog("Прикрепить", isPresented: $showAttachMenu) {
                Button("Фото") { showPhotoPicker = true }
                Button("Музыка") { showAudioPicker = true }
                Button("Видео") { showVideoPicker = true }
                Button("Файл") { showDocPicker = true }
            }
            // GrowingTextEditor вместо TextField — длинный комментарий переносится
            // на вторую строку (как в ЛС), а не скроллится вбок внутри однострочного поля.
            GrowingTextEditor(text: $model.text, placeholder: "Комментарий…", minHeight: 22, maxHeight: 120)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(OVK.Palette.background)
                .cornerRadius(18)
                .focused($inputFocused)
            if model.isSending {
                ProgressView()
            } else {
                Button {
                    Task { await model.send(ownerID: ownerID, postID: postID, settings: settings) }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 22))
                        .foregroundColor(OVK.Palette.primary)
                        .frame(width: 38, height: 38)
                }
                .disabled(!model.canSend)
            }
        }
        .padding(8)
        .background(OVK.Palette.card)
    }
}

