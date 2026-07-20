import SwiftUI

/// Параллельный экран плеера: текст ← сейчас играет → очередь.
///
/// Показывается НЕ модалкой (fullScreenCover убирает экран под собой — размывать нечего,
/// а при потягивании за ним чёрный провал), а ОВЕРЛЕЕМ поверх MainTabView. Так за плеером
/// остаётся живой контент вкладок: его размывает UIVisualEffectView (матовое стекло, как
/// «шторка» iOS 7-10), и при потягивании вниз из-под плеера видно именно приложение, а не чёрное.
struct VKPlayerView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloads: AudioDownloadManager
    /// Текст трека грузится ЗДЕСЬ, а не в странице текста: у прежнего TabView(.page)
    /// .task(id:) не срабатывал на смену id, пока страница была «за кулисами» — текст переставал грузиться.
    /// Контейнер же смонтирован постоянно, поэтому явно ограничиваем загрузку временем,
    /// когда экран открыт; иначе смена трека создаёт сеть/диск поверх прокрутки ленты.
    /// Состояние — в LyricsStore (ObservableObject): hosting-root страницы живёт всю жизнь
    /// плеера и получает новые данные по своей подписке, без замены rootView.
    @StateObject private var lyricsStore = LyricsStore()
    /// Плеер смонтирован и за экраном тоже. Передаём его страницам отдельные часы,
    /// которые тикают только при открытом экране, чтобы скрытые lyrics/slider не
    /// перерисовывались поверх прокрутки ленты.
    @StateObject private var visibleClock = PlaybackClock()
    /// id трека, для которого текст уже загружен/грузится (дедуп повторных вызовов reloadLyrics).
    @State private var loadedLyricsID: String?
    @State private var lyricsTask: Task<Void, Never>?
    @State private var page = 1
    /// Сдвиг всего экрана вниз во время интерактивного закрытия (тянем за шапку).
    @State private var dragOffset: CGFloat = 0
    /// Пока закрываемся, новые касания не должны перезаписывать положение экрана.
    @State private var isClosing = false
    /// alpha-видимость закрытого плеера (см. .opacity ниже). Меняется ТОЛЬКО без анимации
    /// в onChange(isPresented) — держать её на самом isPresented с .animation(nil, value:)
    /// нельзя: на iOS 15 это глушило и анимацию offset (плеер открывался одним кадром).
    @State private var visible = false

    /// За нижним краем с запасом (safe area / тени) — там плеер живёт в закрытом состоянии.
    private var hiddenOffset: CGFloat { UIScreen.main.bounds.height + 60 }

    var body: some View {
        surface
            // Пояс и подтяжки к offset'у ниже: alpha 0 гарантированно выключает UIKit-хит-тест
            // ВСЕХ вложенных UIKit-вью (List, блюр, MPVolumeView) у закрытого плеера.
            // Прозрачность меняется мгновенно и только за краем экрана — фейда не видно.
            .opacity(visible ? 1 : 0)
            // Плеер смонтирован постоянно (см. MainTabView) — открытие лишь анимирует offset,
            // ничего не строя заново, поэтому без лага первого показа.
            .offset(y: isPresented ? dragOffset : hiddenOffset)
            // Во время закрытия экран уже «отпущен» — новые тапы по кнопкам не должны срабатывать.
            .allowsHitTesting(isPresented && !isClosing)
            // Закрытие — UIKit-пан, НЕ SwiftUI DragGesture: SwiftUI-жест конфликтовал с
            // UIKit-распознавателями пейджера/слайдеров (терялся onEnded → экран «застревал»
            // на полпути, медленные горизонтальные свайпы не листали страницы, свайп поверх
            // слайдера не закрывал плеер). См. DismissPanGesture ниже.
            // КРИТИЧНО: якорь нулевого размера. .background следует layout-фрейму, который
            // offset НЕ двигает — полноэкранный якорь у закрытого плеера накрывал ВСЁ приложение
            // и глотал каждый тап. Сам распознаватель живёт на корневом вью, якорь нужен только
            // для монтирования/жизненного цикла.
            .background(DismissPanGesture(
                isEnabled: isPresented,
                onChanged: { offset in
                    guard !isClosing else { return }
                    dragOffset = offset
                },
                onEnded: { translation, velocity in
                    guard !isClosing else { return }
                    // Порог по расстоянию ИЛИ по скорости броска — как у системных шторок.
                    if translation > 110 || velocity > 900 {
                        close(velocity: velocity)
                    } else {
                        springBack()
                    }
                },
                onCancelled: {
                    guard !isClosing else { return }
                    springBack()
                }
            ).frame(width: 0, height: 0))
            .onChange(of: isPresented) { shown in
                var instant = Transaction()
                instant.disablesAnimations = true
                if shown {
                    withTransaction(instant) {
                        dragOffset = 0
                        isClosing = false
                        visible = true
                        visibleClock.currentTime = player.clock.currentTime
                        visibleClock.duration = player.clock.duration
                    }
                    reloadLyrics()
                } else {
                    // Плеер уже уехал за край — просто мгновенно гасим alpha.
                    withTransaction(instant) { visible = false }
                    lyricsTask?.cancel()
                    lyricsTask = nil
                    loadedLyricsID = nil
                    lyricsStore.loading = false
                }
            }
            // НЕ .task(id:): его перезапуск по смене id на iOS 15 ненадёжен (текст просто
            // переставал грузиться). onChange + явная Task — проверенный в этом проекте путь.
            .onAppear { reloadLyrics() }
            .onChange(of: player.current?.id) { _ in reloadLyrics() }
            .onReceive(player.clock.$currentTime) { time in
                if isPresented { visibleClock.currentTime = time }
            }
            .onReceive(player.clock.$duration) { duration in
                if isPresented { visibleClock.duration = duration }
            }
            .toast($library.toast)
    }

    /// Подгружает текст текущего трека в lyricsStore (дедуп по id, отмена предыдущей загрузки).
    /// Скрытый постоянно смонтированный плеер не должен создавать фоновую работу.
    private func reloadLyrics() {
        guard isPresented else { return }
        let track = player.current
        guard track?.id != loadedLyricsID else { return }
        loadedLyricsID = track?.id
        lyricsTask?.cancel()
        guard let track else {
            lyricsStore.lyrics = nil
            lyricsStore.loading = false
            return
        }
        lyricsTask = Task {
            lyricsStore.loading = true
            let found = await LyricsService.shared.lyrics(for: track, settings: settings)
            guard !Task.isCancelled else { return }
            lyricsStore.lyrics = found
            lyricsStore.loading = false
        }
    }

    private func springBack() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            dragOffset = 0
        }
    }

    private var surface: some View {
        VStack(spacing: 0) {
            header
            // НЕ TabView(.page): на iOS 15 его НЕвыбранные страницы замерзают в состоянии
            // на момент создания и не перерисовываются вовсе (плеер монтируется при запуске,
            // до первого трека → страницы текста/очереди навсегда показывали «пусто», хотя
            // подписки и данные были живы). Наш UIScrollView держит каждую страницу в
            // собственном UIHostingController — три постоянно смонтированных живых графа SwiftUI.
            // Environment через границу hosting controller'а НЕ протекает — обязательно
            // прокидывать .environmentObject каждой странице явно.
            PlayerPager(
                selection: $page,
                lyrics: VKPlayerLyricsPage(clock: visibleClock, store: lyricsStore)
                    .environmentObject(player),
                nowPlaying: VKPlayerNowPlayingPage(clock: visibleClock, onRequestClose: { close() })
                    .environmentObject(player)
                    .environmentObject(downloads)
                    .environmentObject(settings)
                    .environmentObject(library),
                queue: VKPlayerQueuePage()
                    .environmentObject(player)
            )
            bottomBar
        }
        // Матовое стекло эпохи iOS 7-10: молочно-белое .extraLight (не сероватое .regular),
        // контент вкладок позади проступает лишь лёгким оттенком. См. docs/vk-player-spec.md.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LightGlassBackground().ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Spacer()
            // Широкая плоская стрелка-«граббер» («︾», как в Apple Music), не компактный шеврон.
            Button { close() } label: {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundColor(OVK.Palette.textSecondary)
                    .frame(width: 72, height: 44)
            }
            Spacer()
        }
        .padding(.top, 8)
        .contentShape(Rectangle())
    }

    /// Закрытие — ОДНА непрерывная анимация dragOffset от позиции пальца за нижний край,
    /// с учётом скорости броска. Снимать binding через withAnimation нельзя: на iOS 15
    /// transaction через binding в overlay родителя доезжает ненадёжно — removal-transition
    /// не анимировался (заминка при отпускании пальца и исчезновение без плавного ухода).
    /// binding снимается БЕЗ анимации, когда экран уже за краем — удаление невидимо.
    /// Гонки повторного касания при таком закрытии исключены isClosing + allowsHitTesting(false).
    private func close(velocity: CGFloat = 0) {
        guard !isClosing else { return }
        isClosing = true
        let height = UIScreen.main.bounds.height
        let remaining = max(height - dragOffset, 1)
        // Быстрый бросок доезжает быстрее; тап по грабберу и медленный свайп — за 0.25с.
        let duration = velocity > 300 ? min(max(Double(remaining / velocity), 0.15), 0.25) : 0.25
        withAnimation(.easeOut(duration: duration)) {
            dragOffset = height
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            isPresented = false
            // Вью живёт постоянно — @State переживает закрытие. Без сброса dragOffset
            // (= высота экрана после close) следующее открытие анимировалось бы лишь
            // на последние ~60pt и «доскакивало» мгновенно.
            dragOffset = 0
            isClosing = false
        }
    }

    private var bottomBar: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundColor(player.isShuffled ? OVK.Palette.primary : OVK.Palette.textSecondary)
            }
            Spacer()
            // Индикатор страниц эпохи: • • ≡ — третья «точка» (очередь) не круг, а глиф списка.
            HStack(spacing: 9) {
                ForEach(0..<2) { index in
                    Circle()
                        .fill(index == page ? OVK.Palette.primary : OVK.Palette.textSecondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(page == 2 ? OVK.Palette.primary : OVK.Palette.textSecondary.opacity(0.35))
            }
            Spacer()
            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundColor(player.repeatMode == .off ? OVK.Palette.textSecondary : OVK.Palette.primary)
            }
        }
        .font(.title3)
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
    }
}

/// Пейджер трёх страниц плеера. Каждая страница — свой UIHostingController и
/// все три контроллера один раз монтируются рядом в UIScrollView. UIPageViewController
/// заменял деревья view прямо во время свайпа; на iPhone SE это давало 94–100 мс
/// в _UIQueuingScrollView._replaceViews. Здесь свайп меняет только contentOffset.
private struct PlayerPager: UIViewControllerRepresentable {
    @Binding var selection: Int
    private let pages: [AnyView]

    init(selection: Binding<Int>, lyrics: some View, nowPlaying: some View, queue: some View) {
        _selection = selection
        pages = [AnyView(lyrics), AnyView(nowPlaying), AnyView(queue)]
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> FixedPagerController {
        let controllers = pages.map { UIHostingController(rootView: $0) }
        // Прозрачность обязательна: фон плеера — общее матовое стекло под всеми страницами.
        controllers.forEach { $0.view.backgroundColor = .clear }
        let start = min(max(selection, 0), controllers.count - 1)
        let pager = FixedPagerController(pages: controllers, selection: start)
        pager.onSelectionChanged = { [weak coordinator = context.coordinator] index in
            coordinator?.select(index)
        }
        return pager
    }

    func updateUIViewController(_ pager: FixedPagerController, context: Context) {
        context.coordinator.parent = self
        // Корневые AnyView не заменяем: страницы наблюдают свои reference-type модели сами.
        pager.setSelection(selection, animated: true)
    }

    final class Coordinator: NSObject {
        var parent: PlayerPager
        init(_ parent: PlayerPager) { self.parent = parent }

        func select(_ index: Int) {
            guard parent.selection != index else { return }
            parent.selection = index
        }
    }
}

/// Все страницы остаются дочерними контроллерами и view одного UIScrollView всю жизнь плеера.
@MainActor
private final class FixedPagerController: UIViewController, UIScrollViewDelegate {
    private let pager = UIScrollView()
    private let pageControllers: [UIViewController]
    private var selectedIndex: Int
    private var lastLaidOutSize: CGSize = .zero
    private var programmaticTarget: Int?
    var onSelectionChanged: ((Int) -> Void)?

    init(pages: [UIViewController], selection: Int) {
        pageControllers = pages
        selectedIndex = selection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        pager.backgroundColor = .clear
        pager.isPagingEnabled = true
        pager.isDirectionalLockEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.showsVerticalScrollIndicator = false
        pager.scrollsToTop = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.delegate = self
        view.addSubview(pager)

        for controller in pageControllers {
            addChild(controller)
            pager.addSubview(controller.view)
            controller.didMove(toParent: self)
        }
        assertFixedHierarchy()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0, size != lastLaidOutSize else { return }
        let widthChanged = lastLaidOutSize.width != size.width
        lastLaidOutSize = size
        pager.frame = view.bounds
        for (index, controller) in pageControllers.enumerated() {
            controller.view.frame = CGRect(x: CGFloat(index) * size.width, y: 0,
                                           width: size.width, height: size.height)
        }
        pager.contentSize = CGSize(width: CGFloat(pageControllers.count) * size.width,
                                   height: size.height)
        // При смене ширины старый pixel-offset больше не обозначает ту же страницу.
        // Изменение только высоты, наоборот, не должно сбрасывать живой свайп.
        if widthChanged {
            selectedIndex = programmaticTarget ?? selectedIndex
            programmaticTarget = nil
            pager.contentOffset = CGPoint(x: CGFloat(selectedIndex) * size.width, y: 0)
        }
        assertFixedHierarchy()
    }

    func setSelection(_ selection: Int, animated: Bool) {
        guard !pageControllers.isEmpty else { return }
        let selection = min(max(selection, 0), pageControllers.count - 1)
        guard selection != selectedIndex, selection != programmaticTarget else { return }
        guard isViewLoaded, pager.bounds.width > 0 else {
            selectedIndex = selection
            return
        }
        // Внешнее обновление binding не должно рвать интерактивный жест.
        guard !pager.isTracking, !pager.isDragging, !pager.isDecelerating else { return }
        programmaticTarget = selection
        pager.setContentOffset(CGPoint(x: CGFloat(selection) * pager.bounds.width, y: 0),
                               animated: animated)
        if !animated { finishPaging() }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        programmaticTarget = nil
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishPaging()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishPaging() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        finishPaging()
    }

    private func finishPaging() {
        guard pager.bounds.width > 0, !pageControllers.isEmpty else { return }
        let index = min(max(Int(round(pager.contentOffset.x / pager.bounds.width)), 0),
                        pageControllers.count - 1)
        programmaticTarget = nil
        selectedIndex = index
        onSelectionChanged?(index)
        assertFixedHierarchy()
    }

    /// Единственный автоматизированный seam этого UIKit-пейджера: в Debug ловит отцепление
    /// страниц, ошибку геометрии при rotation и неверный idle-offset.
    private func assertFixedHierarchy() {
#if DEBUG
        assert(pageControllers.count == 3)
        assert(children.count == pageControllers.count)
        assert(zip(children, pageControllers).allSatisfy { $0 === $1 })
        assert(pageControllers.allSatisfy { $0.parent === self && $0.view.superview === pager })
        assert(pager.delegate === self)
        guard lastLaidOutSize.width > 0 else { return }
        assert(pager.contentSize == CGSize(width: CGFloat(pageControllers.count) * pager.bounds.width,
                                           height: pager.bounds.height))
        for (index, controller) in pageControllers.enumerated() {
            assert(controller.view.frame == CGRect(x: CGFloat(index) * pager.bounds.width, y: 0,
                                                   width: pager.bounds.width, height: pager.bounds.height))
        }
        if !pager.isTracking, !pager.isDragging, !pager.isDecelerating, programmaticTarget == nil {
            assert(abs(pager.contentOffset.x - CGFloat(selectedIndex) * pager.bounds.width) < 0.5)
        }
#endif
    }
}

/// Свайп-вниз для закрытия плеера — настоящий UIPanGestureRecognizer на корневом UIKit-вью
/// (пока плеер открыт, он занимает весь экран). Почему не SwiftUI DragGesture:
/// - при конфликте с UIKit-распознавателями (пейджер UIScrollView, UISlider, MPVolumeView)
///   SwiftUI-жест мог не получить onEnded → dragOffset «застревал» на полпути;
/// - simultaneousGesture мешал медленным горизонтальным свайпам пейджера;
/// - свайп, начатый на слайдере, целиком забирал слайдер.
/// UIKit-пан начинается ТОЛЬКО при явно вертикальном движении вниз (velocity в shouldBegin),
/// горизонтальные жесты вообще не трогает, а начавшись — отменяет касания у контролов
/// (cancelsTouchesInView), поэтому слайдер не дёргается. Терминальное состояние
/// (.ended/.cancelled) UIKit доставляет всегда — «застрять» закрытие не может.
private struct DismissPanGesture: UIViewRepresentable {
    /// Плеер смонтирован постоянно — пока он закрыт, распознаватель на корне ДОЛЖЕН быть
    /// выключен, иначе перехватывал бы вертикальные свайпы по всему приложению.
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    var onCancelled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        // SwiftUI может смонтировать нулевой якорь позже makeUIView или перенести его в
        // другое окно. didMoveToWindow даёт распознавателю надёжный полный экран, а не
        // единственный async-шанс попасть в ещё строящуюся иерархию.
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.install(on: window)
        }
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        context.coordinator.parent = self
        // Повторная попытка закрывает редкий порядок событий, где update приходит уже
        // после didMoveToWindow, но до установки callback в makeUIView.
        context.coordinator.install(on: uiView.window)
    }

    static func dismantleUIView(_ uiView: InstallerView, coordinator: Coordinator) {
        uiView.onWindowChanged = nil
        coordinator.uninstall()
    }

    final class InstallerView: UIView {
        var onWindowChanged: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChanged?(window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: DismissPanGesture
        var pan: UIPanGestureRecognizer?
        init(_ parent: DismissPanGesture) { self.parent = parent }

        func install(on window: UIWindow?) {
            guard let window else {
                if let pan { pan.view?.removeGestureRecognizer(pan) }
                return
            }

            let recognizer: UIPanGestureRecognizer
            if let pan {
                recognizer = pan
            } else {
                recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
                recognizer.delegate = self
                pan = recognizer
            }
            if recognizer.view !== window {
                recognizer.view?.removeGestureRecognizer(recognizer)
                window.addGestureRecognizer(recognizer)
            }
            if recognizer.isEnabled != parent.isEnabled {
                recognizer.isEnabled = parent.isEnabled
            }
#if DEBUG
            assert(recognizer.view === window)
#endif
        }

        func uninstall() {
            guard let pan else { return }
            pan.view?.removeGestureRecognizer(pan)
            pan.delegate = nil
            self.pan = nil
        }

        @objc func handle(_ pan: UIPanGestureRecognizer) {
            let translation = pan.translation(in: pan.view).y
            switch pan.state {
            case .changed:
                parent.onChanged(max(translation, 0))
            case .ended:
                parent.onEnded(translation, pan.velocity(in: pan.view).y)
            case .cancelled, .failed:
                parent.onCancelled()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            // Только явно вертикальный жест вниз — горизонтали остаются пейджеру/слайдерам.
            guard velocity.y > 0, velocity.y > abs(velocity.x) * 1.5 else { return false }
            // Как у системных sheet: внутри прокрутки (текст/очередь) свайп-вниз закрывает,
            // только когда контент у верхнего края — иначе это обычный скролл.
            var hit = view.hitTest(pan.location(in: view), with: nil)
            while let current = hit {
                if let scroll = current as? UIScrollView,
                   scroll.contentSize.height > scroll.bounds.height, // вертикальная прокрутка (не пейджер)
                   scroll.contentOffset.y > -scroll.adjustedContentInset.top + 1 {
                    return false
                }
                hit = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Пейджеру/спискам (UIScrollView) одновременность НЕ даём: во время закрытия
            // страницы не должны листаться. Вертикальный пан горизонтальный пейджер и так
            // не заберёт (его pan на чисто вертикальном жесте фейлится), а начав закрытие,
            // мы блокируем его листание. Остальным (long-press и т.п.) не мешаем.
            !(other.view is UIScrollView)
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard gesture === pan,
                  let scroll = other.view as? UIScrollView else { return false }
            // Вложенный список/текст ждёт решения корневого пана. Наш shouldBegin быстро
            // отказывает горизонтали, движению вверх и движению внутри неверхней позиции;
            // только свайп вниз у верхнего края получает приоритет и закрывает плеер.
            return other === scroll.panGestureRecognizer
        }
    }
}
