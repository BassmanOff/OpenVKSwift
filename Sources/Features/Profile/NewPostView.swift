import SwiftUI

/// Экран создания записи: текст + фото + граффити.
struct NewPostView: View {
    let ownerID: Int
    var onPosted: () -> Void
    /// Название сообщества — задаётся, когда постим на стену группы, которой управляем
    /// (GroupView). nil = обычная личная запись, никаких флагов от_группы не шлём.
    var groupName: String? = nil

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = NewPostViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showPhotoPicker = false
    @State private var showGraffiti = false
    @State private var showAudioPicker = false
    @State private var showVideoPicker = false
    @State private var showDocPicker = false
    @State private var showPollComposer = false
    // По умолчанию постим ОТ ИМЕНИ сообщества — это и есть смысл экрана «управление группой».
    @State private var postAsGroup: Bool
    @State private var signed = false

    init(ownerID: Int, groupName: String? = nil, onPosted: @escaping () -> Void) {
        self.ownerID = ownerID
        self.groupName = groupName
        self.onPosted = onPosted
        _postAsGroup = State(initialValue: groupName != nil)
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                if let groupName { identityBar(groupName) }
                textEditor
                if !model.images.isEmpty { attachments }
                if !model.audioTracks.isEmpty { audioAttachments }
                if !model.videos.isEmpty { videoAttachments }
                if !model.docs.isEmpty { docAttachments }
                if let draft = model.pollDraft { pollAttachment(draft) }
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
                                if await model.publish(
                                    ownerID: ownerID, settings: settings,
                                    fromGroup: postAsGroup, signed: signed
                                ) {
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
            .sheet(isPresented: $showAudioPicker) {
                AudioAttachPicker { model.addAudio($0) }
            }
            .sheet(isPresented: $showVideoPicker) {
                VideoAttachPicker { model.addVideo($0) }
            }
            .sheet(isPresented: $showDocPicker) {
                DocAttachPicker { model.addDoc($0) }
            }
            .sheet(isPresented: $showPollComposer) {
                PollComposerView(initial: model.pollDraft) { model.setPoll($0) }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func identityBar(_ groupName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("От имени «\(groupName)»", isOn: $postAsGroup)
            if postAsGroup {
                Toggle("Подписать моим именем", isOn: $signed)
                    .font(.footnote)
            }
        }
        .padding()
        .background(OVK.Palette.background)
    }

    private var textEditor: some View {
        VStack(alignment: .trailing, spacing: 0) {
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
            // Не мешаем на обычных постах — счётчик только когда реально приближаемся к лимиту.
            if model.text.count > NewPostViewModel.maxTextLength - 2000 {
                Text("\(model.text.count) / \(NewPostViewModel.maxTextLength)")
                    .font(.caption2)
                    .foregroundColor(model.text.count > NewPostViewModel.maxTextLength ? .red : OVK.Palette.textSecondary)
                    .padding(.trailing, 16)
            }
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

    private var audioAttachments: some View {
        VStack(spacing: 6) {
            ForEach(Array(model.audioTracks.enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .foregroundColor(OVK.Palette.primary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.subheadline).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundColor(OVK.Palette.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Button { model.removeAudio(at: index) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(OVK.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 4)
    }

    private var videoAttachments: some View {
        VStack(spacing: 6) {
            ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                HStack(spacing: 8) {
                    CachedImage(url: video.thumbURL) {
                        ZStack { OVK.Palette.background; Image(systemName: "play.rectangle").foregroundColor(OVK.Palette.textSecondary) }
                    }
                    .frame(width: 60, height: 40)
                    .clipped()
                    .cornerRadius(4)
                    Text(video.title).font(.subheadline).lineLimit(1)
                    Spacer()
                    Button { model.removeVideo(at: index) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(OVK.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 4)
    }

    private var docAttachments: some View {
        VStack(spacing: 6) {
            ForEach(Array(model.docs.enumerated()), id: \.element.id) { index, doc in
                HStack(spacing: 8) {
                    Image(systemName: "doc").foregroundColor(OVK.Palette.primary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(doc.title).font(.subheadline).lineLimit(1)
                        Text(doc.sizeText).font(.caption).foregroundColor(OVK.Palette.textSecondary)
                    }
                    Spacer()
                    Button { model.removeDoc(at: index) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(OVK.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 4)
    }

    private func pollAttachment(_ draft: PollDraft) -> some View {
        Button { showPollComposer = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar").foregroundColor(OVK.Palette.primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(draft.question).font(.subheadline).lineLimit(1)
                        .foregroundColor(OVK.Palette.textPrimary)
                    Text("\(draft.trimmedAnswers.count) вариантов").font(.caption).foregroundColor(OVK.Palette.textSecondary)
                }
                Spacer()
                Button { model.removePoll() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(OVK.Palette.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 24) {
                Button { showPhotoPicker = true } label: {
                    Label("Фото", systemImage: "photo")
                }
                Menu {
                    Button { showGraffiti = true } label: {
                        Label("Граффити", systemImage: "scribble.variable")
                    }
                    Button { showAudioPicker = true } label: {
                        Label("Музыка", systemImage: "music.note")
                    }
                    Button { showVideoPicker = true } label: {
                        Label("Видео", systemImage: "video")
                    }
                    Button { showDocPicker = true } label: {
                        Label("Файл", systemImage: "doc")
                    }
                    Button { showPollComposer = true } label: {
                        Label("Голосование", systemImage: "chart.bar")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                Spacer()
            }
            .disabled(!model.canAddMoreImages)
            .opacity(model.canAddMoreImages ? 1 : 0.4)

            if !model.canAddMoreImages {
                Text("Максимум \(NewPostViewModel.maxAttachments) вложений")
                    .font(.caption2)
                    .foregroundColor(OVK.Palette.textSecondary)
            }
        }
        .foregroundColor(OVK.Palette.primary)
        .padding()
    }
}
