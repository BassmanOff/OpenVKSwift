import SwiftUI
import UIKit
import Photos

// MARK: - Координатор

/// Открытое фото + рамка исходной миниатюры (в глобальных координатах) для hero-анимации.
struct PhotoHeroState: Identifiable {
    let id = UUID()
    let photos: [Photo]
    var index: Int
    let post: Post?
    let sourceFrame: CGRect
}

/// Глобальный координатор просмотра фото с «вылетом» из миниатюры и обратно.
@MainActor
final class PhotoHeroCoordinator: ObservableObject {
    @Published var state: PhotoHeroState?

    func present(photos: [Photo], index: Int, sourceFrame: CGRect, post: Post?) {
        state = PhotoHeroState(photos: photos, index: index, post: post, sourceFrame: sourceFrame)
    }
}

// MARK: - Модификатор миниатюры

extension View {
    /// Делает миниатюру фото открываемой в hero-просмотрщике: тап запоминает её экранную
    /// рамку и открывает полноэкранный просмотр с плавным «вылетом» из этого места.
    func photoHeroSource(
        photos: [Photo],
        index: Int,
        post: Post?,
        coordinator: PhotoHeroCoordinator
    ) -> some View {
        overlay(
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let frame = geo.frame(in: .global)
                        Task { @MainActor in
                            coordinator.present(
                                photos: photos, index: index, sourceFrame: frame, post: post
                            )
                        }
                    }
            }
        )
    }
}

// MARK: - Оверлей (ставится поверх всего приложения)

struct PhotoHeroOverlay: View {
    @EnvironmentObject private var coordinator: PhotoHeroCoordinator

    var body: some View {
        if let state = coordinator.state {
            PhotoHeroView(state: state) {
                coordinator.state = nil
            }
            .id(state.id)
            .ignoresSafeArea()
            .transition(.identity)
        }
    }
}

// MARK: - Просмотрщик

private enum HeroPhase { case expanding, open, closing }

private struct PhotoHeroView: View {
    let state: PhotoHeroState
    let onFinish: () -> Void

    @EnvironmentObject private var likes: LikesManager
    @EnvironmentObject private var settings: AppSettings

    @State private var phase: HeroPhase = .expanding
    @State private var index: Int
    @State private var progress: CGFloat = 0        // 0 — в миниатюре, 1 — раскрыто
    @State private var dragOffset: CGSize = .zero    // смахивание вниз
    @State private var dragProgress: CGFloat = 1     // 1 — открыто, 0 — у миниатюры (при смахивании)
    @State private var chromeHidden = false
    @State private var showMenu = false
    @State private var showComments = false
    @State private var shareItem: HeroShareItem?
    @State private var toast: String?

    init(state: PhotoHeroState, onFinish: @escaping () -> Void) {
        self.state = state
        self.onFinish = onFinish
        _index = State(initialValue: state.index)
    }

    private var currentPhoto: Photo? { state.photos.indices.contains(index) ? state.photos[index] : nil }
    private var backgroundOpacity: Double { Double(min(progress, dragProgress)) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(backgroundOpacity).ignoresSafeArea()

                content(fullSize: geo.size)

                if phase == .open && !chromeHidden {
                    chrome
                        .opacity(Double(dragProgress))
                }
            }
            .onAppear { expand() }
        }
        .statusBar(hidden: true)
        .confirmationDialog("", isPresented: $showMenu, titleVisibility: .hidden) {
            Button("Скачать фото") { PhotoActions.save(currentPhoto?.bestURL) { toast = $0 } }
            Button("Копировать") { PhotoActions.copy(currentPhoto?.bestURL) { toast = $0 } }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(isPresented: $showComments) {
            if let post = state.post { CommentsView(ownerID: post.ownerID, postID: post.postID) }
        }
        .sheet(item: $shareItem) { HeroShareSheet(items: $0.items) }
        .toast($toast)
    }

    // MARK: Контент

    @ViewBuilder
    private func content(fullSize: CGSize) -> some View {
        if phase == .open {
            // Раскрыто: листание + зум.
            TabView(selection: $index) {
                ForEach(Array(state.photos.enumerated()), id: \.offset) { i, photo in
                    ZoomablePhoto(
                        url: photo.bestURL,
                        onSwipeDismiss: { translation in handleSwipe(translation, fullSize: fullSize) },
                        onSwipeEnd: { translation, velocity in endSwipe(translation, velocity: velocity) },
                        onTap: { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }
                    )
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(dragOffset)
            .scaleEffect(0.6 + 0.4 * dragProgress)   // слегка уменьшается при смахивании
        } else {
            // Анимация «вылета»: одиночное фото интерполируется между миниатюрой и экраном.
            let target = fitFrame(for: currentPhoto, in: fullSize)
            let frame = interpolate(from: state.sourceFrame, to: target, t: progress)
            HeroImage(url: currentPhoto?.bestURL, cornerRadius: (1 - progress) * 6)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
    }

    // MARK: Анимации

    private func expand() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            progress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if phase == .expanding { phase = .open }
        }
    }

    private func handleSwipe(_ translation: CGSize, fullSize: CGSize) {
        dragOffset = translation
        dragProgress = max(0, 1 - translation.height / 400)
    }

    private func endSwipe(_ translation: CGSize, velocity: CGFloat) {
        if translation.height > 140 || velocity > 900 {
            close()
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                dragOffset = .zero
                dragProgress = 1
            }
        }
    }

    private func close() {
        // Возврат к миниатюре: показываем одиночное фото и стягиваем в исходную рамку.
        // Стартовый progress = текущий (при смахивании фото уже уменьшено) — без скачка размера.
        phase = .closing
        progress = min(progress, dragProgress)
        dragProgress = 1
        dragOffset = .zero
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            progress = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { onFinish() }
    }

    // MARK: Геометрия

    /// Рамка фото при вписывании (scaledToFit) в экран.
    private func fitFrame(for photo: Photo?, in size: CGSize) -> CGRect {
        let ratio = photo?.aspectRatio ?? 1
        var w = size.width
        var h = w / ratio
        if h > size.height { h = size.height; w = h * ratio }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func interpolate(from a: CGRect, to b: CGRect, t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    // MARK: Интерфейс

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack {
                Button { close() } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold)).foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
                Spacer()
                Text("\(index + 1) из \(state.photos.count)")
                    .font(.subheadline).fontWeight(.semibold).foregroundColor(.white)
                Spacer()
                Button { showMenu = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.semibold)).foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 44)
            .background(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())

            Spacer()

            if let post = state.post { bottomBar(post) }
        }
    }

    private func bottomBar(_ post: Post) -> some View {
        HStack(spacing: 28) {
            Button { likes.toggle(post, settings: settings) } label: {
                actionLabel(likes.isLiked(post) ? "heart.fill" : "heart", "\(likes.count(post))",
                            tint: likes.isLiked(post) ? .red : .white)
            }
            Button { showComments = true } label: {
                actionLabel("bubble.right", "\(post.commentsCount)", tint: .white)
            }
            Button { if let url = currentPhoto?.bestURL { shareItem = HeroShareItem(items: [url]) } } label: {
                actionLabel("arrowshape.turn.up.right", "\(post.repostsCount)", tint: .white)
            }
            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 34)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func actionLabel(_ icon: String, _ text: String, tint: Color) -> some View {
        HStack(spacing: 6) { Image(systemName: icon); Text(text) }
            .font(.subheadline).foregroundColor(tint)
    }
}

// MARK: - Кадр для hero-анимации (без зума)

private struct HeroImage: View {
    let url: URL?
    let cornerRadius: CGFloat
    var body: some View {
        CachedImage(url: url, contentMode: .fit, maxPixelSize: 2048) { Color.black }
            .cornerRadius(cornerRadius)
    }
}

// MARK: - Зумируемое фото (нативные жесты)

private struct ZoomablePhoto: View {
    let url: URL?
    let onSwipeDismiss: (CGSize) -> Void
    let onSwipeEnd: (CGSize, CGFloat) -> Void
    let onTap: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            CachedImage(url: url, contentMode: .fit, maxPixelSize: 2048) {
                ProgressView().tint(.white)
            }
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(magnification)
            // simultaneous — чтобы горизонтальное листание TabView продолжало работать;
            // наш жест реагирует только на вертикаль вниз (смахивание) и на панораму при зуме.
            .simultaneousGesture(dragGesture(size: geo.size))
            .onTapGesture(count: 2) { toggleZoom() }
            .onTapGesture { onTap() }
        }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in scale = min(max(lastScale * value, 1), 4) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { withAnimation(.spring(response: 0.3)) { resetPan() } }
            }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 {
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                } else if value.translation.height > 0 {
                    onSwipeDismiss(value.translation) // смахивание вниз (не увеличено)
                }
            }
            .onEnded { value in
                if scale > 1 {
                    lastOffset = offset
                } else if value.translation.height > 0 {
                    onSwipeEnd(value.translation, value.predictedEndTranslation.height - value.translation.height)
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3)) {
            if scale > 1 { resetPan() } else { scale = 2.5; lastScale = 2.5 }
        }
    }

    private func resetPan() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
    }
}

// MARK: - Действия / шаринг (общие)

enum PhotoActions {
    static func save(_ url: URL?, note: @escaping (String) -> Void) {
        guard let url else { return }
        Task {
            guard let image = await loadImage(url) else { return }
            let granted = await requestAdd()
            guard granted else { note("Нет доступа к «Фото»"); return }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            note("Фото сохранено")
        }
    }
    static func copy(_ url: URL?, note: @escaping (String) -> Void) {
        guard let url else { return }
        Task {
            if let image = await loadImage(url) {
                UIPasteboard.general.image = image
                note("Фото скопировано")
            }
        }
    }
    private static func loadImage(_ url: URL) async -> UIImage? {
        guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
        return UIImage(data: data)
    }
    private static func requestAdd() async -> Bool {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                cont.resume(returning: status == .authorized || status == .limited)
            }
        }
    }
}

private struct HeroShareItem: Identifiable { let id = UUID(); let items: [Any] }
private struct HeroShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
