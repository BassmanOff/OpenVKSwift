import SwiftUI
import UIKit
import Photos
import Combine

// MARK: - Просмотрщик фото (галерея в стиле Telegram, чистый UIKit)
//
// Архитектура (как в галереях Telegram/VK):
// • Тап по миниатюре живёт на UIKit-слое размером с миниатюру — рамка для «вылета»
//   берётся у НЕГО ЖЕ в момент тапа (self-verifying: тап сработал → рамка настоящая).
// • Галерея — UIViewController в отдельном окне поверх всего (включая sheet'ы).
// • Открытие/закрытие — обычная UIView-анимация кадров UIImageView: никаких SwiftUI-
//   транзакций, safe area и GeometryReader в геометрии перехода не участвуют.
// • Цель закрытия ПЕРЕЗАПРАШИВАЕТСЯ у исходной ячейки в момент закрытия
//   (лента могла прокрутиться); ячейка исчезла — мягкое затухание, как в Telegram.
// • Полёт обрезается видимой областью списка → фото уходит ПОД шапку и нижнее меню.

/// Синхронный поиск уже декодированной картинки в память-кэше по всем типовым ключам
/// (полный размер просмотрщика, экранный размер ленты, «raw»-конвейер без оптимизации).
private func heroCachedImage(_ url: URL?) -> UIImage? {
    guard let url else { return nil }
    let screen = CachedImage<EmptyView>.screenPixelWidth
    return ImageCache.shared.image(for: url, maxPixelSize: 2048)
        ?? ImageCache.shared.image(for: url, maxPixelSize: screen)
        ?? ImageCache.shared.image(for: url, maxPixelSize: screen, raw: true)
}

// MARK: - Координатор

@MainActor
final class PhotoHeroCoordinator: ObservableObject {
    // Зависимости для галереи (лайки, комментарии, вложения) — заполняет PhotoHeroWindowMount.
    var settings: AppSettings?
    var likes: LikesManager?
    var player: AudioPlayer?
    var downloads: AudioDownloadManager?
    var library: LibraryManager?

    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?

    /// Реестр «фото → его миниатюра на экране»: пролистав в галерее к другому фото,
    /// закрытие летит В ЕГО СОБСТВЕННУЮ миниатюру (а не в исходно тапнутую).
    private struct WeakView { weak var view: UIView? }
    private var sources: [String: WeakView] = [:]

    func registerSource(_ view: UIView, for photoID: String) {
        sources[photoID] = WeakView(view: view)
    }

    /// Живая (видимая на экране) миниатюра данного фото, если есть.
    func sourceView(for photoID: String) -> UIView? {
        guard let view = sources[photoID]?.view, view.window != nil else { return nil }
        return view
    }

    /// Открывает галерею. `sourceView` — невидимый слой ровно над миниатюрой:
    /// у него берём рамку старта и (при закрытии) рамку возврата.
    func present(photos: [Photo], index: Int, post: Post?, from sourceView: UIView) {
        guard window == nil, let scene = sourceView.window?.windowScene else { return }

        let gallery = PhotoGalleryController(
            photos: photos, index: index, post: post,
            sourceView: sourceView, deps: self
        )
        gallery.onClosed = { [weak self] in
            self?.window?.isHidden = true
            self?.window = nil
            self?.previousKeyWindow?.makeKey() // вернуть статус-бару стиль приложения
        }

        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        w.backgroundColor = .clear
        w.rootViewController = gallery
        // Key — обязательно: стиль статус-бара берётся у KEY-окна, иначе поверх фото
        // остаются ЧЁРНЫЕ иконки светлой темы приложения.
        w.makeKeyAndVisible()
        window = w
    }
}

// MARK: - Мост из SwiftUI-окружения (ставится в RootView)

/// Передаёт менеджеры из SwiftUI-окружения координатору галереи (UIKit их сам не видит).
struct PhotoHeroWindowMount: View {
    @EnvironmentObject private var coordinator: PhotoHeroCoordinator
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var likes: LikesManager
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: AudioDownloadManager
    @EnvironmentObject private var library: LibraryManager

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                coordinator.settings = settings
                coordinator.likes = likes
                coordinator.player = player
                coordinator.downloads = downloads
                coordinator.library = library
            }
    }
}

// MARK: - Модификатор миниатюры

extension View {
    /// Делает миниатюру фото открываемой в галерее: тап запоминает её слой
    /// и открывает полноэкранный просмотр с «вылетом» из этого места.
    func photoHeroSource(
        photos: [Photo],
        index: Int,
        post: Post?,
        coordinator: PhotoHeroCoordinator
    ) -> some View {
        overlay(
            HeroTapProbe(
                onMount: { view in
                    // Регистрируем миниатюру: закрытие галереи найдёт её по id фото.
                    guard photos.indices.contains(index) else { return }
                    let photoID = photos[index].id
                    Task { @MainActor in coordinator.registerSource(view, for: photoID) }
                },
                onTap: { view in
                    Task { @MainActor in
                        coordinator.present(photos: photos, index: index, post: post, from: view)
                    }
                }
            )
        )
    }
}

/// Невидимый UIKit-слой размером ровно с миниатюру; тап живёт НА НЁМ ЖЕ.
/// Если тап открыл галерею — значит, у слоя гарантированно настоящая экранная рамка.
private struct HeroTapProbe: UIViewRepresentable {
    let onMount: (UIView) -> Void
    let onTap: (UIView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        context.coordinator.view = view
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tap))
        view.addGestureRecognizer(tap)
        onMount(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.view = uiView
        context.coordinator.onTap = onTap
        onMount(uiView) // ячейку List могли переиспользовать под другое фото
    }

    final class Coordinator: NSObject {
        var onTap: (UIView) -> Void
        weak var view: UIView?

        init(onTap: @escaping (UIView) -> Void) { self.onTap = onTap }

        @objc func tap() {
            if let view { onTap(view) }
        }
    }
}

// MARK: - Контроллер галереи

@MainActor
final class PhotoGalleryController: UIViewController, UIScrollViewDelegate {
    private let photos: [Photo]
    private var index: Int
    /// С какого фото открылись — исходная миниатюра валидна как цель закрытия
    /// только пока смотрим это же фото.
    private let initialIndex: Int
    private let post: Post?
    private weak var sourceView: UIView?
    private unowned let deps: PhotoHeroCoordinator
    var onClosed: (() -> Void)?

    // Слои (снизу вверх): фон → пейджер → кадр перехода → интерфейс.
    private let dimView = UIView()
    private let pager = UIScrollView()
    private var pages: [ZoomPageView] = []
    private let topBar = UIView()
    private let bottomBar = UIView()
    private let topGradient = CAGradientLayer()
    private let bottomGradient = CAGradientLayer()
    private let counterLabel = UILabel()
    private let likeButton = UIButton(type: .system)
    private let commentButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)

    private var likesSink: AnyCancellable?
    private var didAnimateIn = false
    private var isClosing = false
    private var chromeHidden = false
    private var lastLaidOutSize: CGSize = .zero
    /// Safe-area top ОСНОВНОГО окна при видимом статус-баре (замер до его скрытия).
    /// Нужен на закрытии: компенсировать сдвиг ленты, если её пересборка под
    /// вернувшийся статус-бар ещё не успела к моменту замера цели.
    private var mainSafeAreaTop: CGFloat = 0

    init(photos: [Photo], index: Int, post: Post?,
         sourceView: UIView, deps: PhotoHeroCoordinator) {
        self.photos = photos
        self.index = index
        self.initialIndex = index
        self.post = post
        self.sourceView = sourceView
        self.deps = deps
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Белые иконки на время переходов (открытие/закрытие).
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    /// Пока фото раскрыто — статус-бар СКРЫТ. Прятать/показывать можно только когда
    /// чёрный фон полностью непрозрачен: скрытие меняет safe area ОСНОВНОГО окна
    /// (iPhone без чёлки) и лента перекомпоновывается — за непрозрачным фоном
    /// этого не видно. Поэтому: прячем в completion открытия, показываем В НАЧАЛЕ закрытия.
    private var statusBarHidden = false {
        didSet { setNeedsStatusBarAppearanceUpdate() }
    }
    override var prefersStatusBarHidden: Bool { statusBarHidden }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    private var currentPhoto: Photo? {
        photos.indices.contains(index) ? photos[index] : nil
    }

    // MARK: Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.backgroundColor = .black
        dimView.alpha = 0
        view.addSubview(dimView)

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.contentInsetAdjustmentBehavior = .never // никакой safe area в геометрии
        pager.delegate = self
        pager.alpha = 0 // покажем после анимации открытия
        view.addSubview(pager)

        for photo in photos {
            let page = ZoomPageView(photo: photo)
            page.onSingleTap = { [weak self] in self?.toggleChrome() }
            page.onDismissChanged = { [weak self] translation in self?.dragChanged(translation) }
            page.onDismissEnded = { [weak self] translation, velocity in
                self?.dragEnded(translation, velocity: velocity)
            }
            pages.append(page)
            pager.addSubview(page)
        }

        buildChrome()
        refreshCounter()
        refreshLikeButton()

        // Лайк мог измениться из комментариев/другого экрана — держим кнопку свежей.
        likesSink = deps.likes?.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshLikeButton() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        dimView.frame = view.bounds

        // Раскладываем пейджер только когда размер реально сменился —
        // иначе сбросим позицию при каждом проходе layout.
        if size != lastLaidOutSize {
            lastLaidOutSize = size
            pager.frame = view.bounds
            for (i, page) in pages.enumerated() {
                page.frame = CGRect(x: CGFloat(i) * size.width, y: 0,
                                    width: size.width, height: size.height)
            }
            pager.contentSize = CGSize(width: CGFloat(pages.count) * size.width,
                                       height: size.height)
            pager.contentOffset = CGPoint(x: CGFloat(index) * size.width, y: 0)
        }
        layoutChrome()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAnimateIn else { return }
        didAnimateIn = true
        mainSafeAreaTop = sourceView?.window?.safeAreaInsets.top ?? 0 // бар ещё виден
        loadPages(around: index)
        animateIn()
    }

    // MARK: Геометрия

    /// Рамка миниатюры В КООРДИНАТАХ нашего view — перезапрашивается каждый раз
    /// (при закрытии лента могла прокрутиться, ячейка сместилась).
    private func rect(of thumb: UIView?) -> CGRect? {
        guard let thumb, thumb.window != nil else { return nil }
        let rect = thumb.convert(thumb.bounds, to: view) // конверсия через экран
        guard rect.width > 1, rect.height > 1 else { return nil }
        return rect
    }

    /// Видимая область списка вокруг миниатюры: ей обрезаем полёт,
    /// чтобы фото уходило ПОД шапку раздела и нижнее меню.
    private func containerRect(around thumb: UIView?) -> CGRect {
        guard let thumb else { return view.bounds }
        var ancestor = thumb.superview
        while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
        guard let scroll = ancestor else { return view.bounds }
        let rect = scroll.convert(scroll.bounds, to: view)
        return rect.width > 1 ? rect : view.bounds
    }

    /// Миниатюра, В КОТОРУЮ закрываться: своя миниатюра ТЕКУЩЕГО фото (мог пролистать),
    /// иначе исходно тапнутая (только если всё ещё смотрим то же фото), иначе nil → затухание.
    private func closeTargetView() -> UIView? {
        if let photo = currentPhoto, let registered = deps.sourceView(for: photo.id) {
            return registered
        }
        if index == initialIndex { return sourceView }
        return nil
    }

    /// Рамка фото при вписывании в экран (scaledToFit).
    private func fitRect(for photo: Photo?, in bounds: CGRect) -> CGRect {
        let ratio = photo?.aspectRatio ?? 1
        var w = bounds.width
        var h = w / ratio
        if h > bounds.height { h = bounds.height; w = h * ratio }
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    // MARK: Открытие

    private func animateIn() {
        let fit = fitRect(for: currentPhoto, in: view.bounds)
        let start = rect(of: sourceView)
        let container = containerRect(around: sourceView)
        print("[Gallery] open: source=\(start.map(String.init(describing:)) ?? "nil") container=\(container)")

        guard let start else {
            // Рамки нет (не должно случаться: тап пришёл с живого слоя) — просто проявляемся.
            pager.alpha = 1
            UIView.animate(withDuration: 0.22) {
                self.dimView.alpha = 1
                self.setChromeAlpha(1)
            } completion: { _ in
                self.statusBarHidden = true // фон уже непрозрачный
            }
            return
        }

        // Кадр перехода: aspectFill в рамке ячейки выглядит как миниатюра (сетка кадрирует),
        // в рамке fit совпадает с фото на странице — непрерывная картинка на всём пути.
        let clip = UIView(frame: container)
        clip.clipsToBounds = true
        let imageView = UIImageView()
        imageView.image = heroCachedImage(currentPhoto?.bestURL)
            ?? heroCachedImage(currentPhoto?.thumbURL)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 4
        imageView.frame = view.convert(start, to: clip)
        clip.addSubview(imageView)
        view.insertSubview(clip, aboveSubview: pager)

        setChromeAlpha(0)

        // Обе рамки анимируются одной кривой: экранное положение фото непрерывно,
        // а границы обрезки расширяются от области списка до всего экрана.
        UIView.animate(withDuration: 0.45, delay: 0,
                       usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                       options: [.curveEaseInOut]) {
            clip.frame = self.view.bounds
            imageView.frame = fit
            imageView.layer.cornerRadius = 0
            self.dimView.alpha = 1
        } completion: { _ in
            self.pager.alpha = 1 // под кадром уже лежит страница с тем же изображением
            clip.removeFromSuperview()
            self.statusBarHidden = true // фон непрозрачен: reflow ленты за ним не виден
            UIView.animate(withDuration: 0.15) { self.setChromeAlpha(1) }
            // Пользователь почти наверняка будет листать: догружаем ВСЕ фото поста
            // в фоне (сеть + декод вне главного потока) — листание без ожидания.
            self.pages.forEach { $0.load() }
        }
    }

    // MARK: Закрытие

    private func close(from translation: CGPoint = .zero) {
        guard !isClosing else { return }
        isClosing = true
        // Статус-бар возвращаем СЕЙЧАС: фон ещё непрозрачен, перекомпоновка ленты
        // из-за смены safe area происходит невидимо, за чёрным.
        statusBarHidden = false

        let photo = currentPhoto
        let fit = fitRect(for: photo, in: view.bounds).offsetBy(dx: translation.x, dy: translation.y)
        let targetView = closeTargetView() // миниатюра ИМЕННО текущего фото

        // Возврат статус-бара сдвигает ленту основного окна ВНИЗ (safe area top
        // вернулась), но пересборка может не успеть к замеру — цель выходила ВЫШЕ
        // ячейки. Форсируем layout и довешиваем ещё не применённый сдвиг явно.
        let mainWindow = (targetView ?? sourceView)?.window
        mainWindow?.layoutIfNeeded()
        let appliedTop = mainWindow?.safeAreaInsets.top ?? mainSafeAreaTop
        let delta = mainSafeAreaTop - appliedTop

        let target = rect(of: targetView)?.offsetBy(dx: 0, dy: delta)
        var container = containerRect(around: targetView ?? sourceView)
        if delta != 0, container != view.bounds {
            container.origin.y += delta       // верх области списка съезжает вниз,
            container.size.height -= delta    // низ (таб-бар) остаётся на месте
        }
        print("[Gallery] close: target=\(target.map(String.init(describing:)) ?? "nil") container=\(container) delta=\(delta)")

        // Кадр перехода поверх пейджера, пейджер прячем.
        let clip = UIView(frame: view.bounds)
        clip.clipsToBounds = true
        let imageView = UIImageView()
        imageView.image = pages.indices.contains(index) ? pages[index].currentImage : nil
        if imageView.image == nil {
            imageView.image = heroCachedImage(photo?.bestURL) ?? heroCachedImage(photo?.thumbURL)
        }
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = fit
        clip.addSubview(imageView)
        view.insertSubview(clip, aboveSubview: pager)
        pager.isHidden = true

        UIView.animate(withDuration: 0.12) { self.setChromeAlpha(0) }

        if let target {
            // Возврат ровно в ячейку (перезапрошенную!), с обрезкой областью списка.
            // Рамка картинки — в координатах clip: обе рамки анимируются одной кривой,
            // их сумма даёт непрерывный экранный путь fit → ячейка.
            UIView.animate(withDuration: 0.35, delay: 0,
                           usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
                clip.frame = container
                imageView.frame = CGRect(x: target.minX - container.minX,
                                         y: target.minY - container.minY,
                                         width: target.width, height: target.height)
                imageView.layer.cornerRadius = 4
                self.dimView.alpha = 0
            } completion: { _ in
                // Не «жёсткий» показ ленты, а короткий кросс-фейд: если ячейка под кадром
                // успела измениться (лента дообновилась/переехала), не будет резкой подмены
                // картинки в конце. При совпадении ячейки фейд между одинаковыми — незаметен.
                UIView.animate(withDuration: 0.1, animations: { clip.alpha = 0 }) { _ in
                    self.onClosed?()
                }
            }
        } else {
            // Ячейка уехала/переиспользована — мягкое затухание на месте (как в Telegram).
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn]) {
                imageView.frame = fit.insetBy(dx: fit.width * 0.15, dy: fit.height * 0.15)
                imageView.alpha = 0
                self.dimView.alpha = 0
            } completion: { _ in
                self.onClosed?()
            }
        }
    }

    // MARK: Смахивание (двигаем страницу, фон/интерфейс тают)

    private func dragChanged(_ translation: CGPoint) {
        guard !isClosing, pages.indices.contains(index) else { return }
        pages[index].transform = CGAffineTransform(translationX: translation.x, y: translation.y)
        let fade = 1 - min(abs(translation.y) / 320, 1)
        dimView.alpha = fade
        if !chromeHidden { setChromeAlpha(fade) }
    }

    private func dragEnded(_ translation: CGPoint, velocity: CGFloat) {
        guard !isClosing, pages.indices.contains(index) else { return }
        if abs(translation.y) > 130 || abs(velocity) > 800 {
            pages[index].transform = .identity
            close(from: translation)
        } else {
            UIView.animate(withDuration: 0.3, delay: 0,
                           usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                self.pages[self.index].transform = .identity
                self.dimView.alpha = 1
                if !self.chromeHidden { self.setChromeAlpha(1) }
            }
        }
    }

    // MARK: Пейджер

    /// Индекс отслеживаем НЕПРЕРЫВНО (didScroll, а не только didEndDecelerating):
    /// иначе закрытие сразу после листания брало бы СТАРЫЙ индекс — и в ленту
    /// «возвращалось» не то фото, которое смотрели.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager, scrollView.bounds.width > 0, !isClosing else { return }
        let raw = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
        let newIndex = min(max(raw, 0), photos.count - 1)
        if newIndex != index {
            index = newIndex
            refreshCounter()
            loadPages(around: index)
        }
    }

    /// Текущая страница и соседи — в первую очередь (остальные фото поста догружаются
    /// фоном после завершения анимации открытия, см. animateIn).
    private func loadPages(around center: Int) {
        for i in max(0, center - 1)...min(pages.count - 1, center + 1) {
            pages[i].load()
        }
    }

    // MARK: Интерфейс

    private func buildChrome() {
        topGradient.colors = [UIColor.black.withAlphaComponent(0.55).cgColor,
                              UIColor.clear.cgColor]
        topBar.layer.insertSublayer(topGradient, at: 0)
        view.addSubview(topBar)

        let back = UIButton(type: .system)
        back.setImage(UIImage(systemName: "chevron.left",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)),
                      for: .normal)
        back.tintColor = .white
        back.tag = 1
        back.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        topBar.addSubview(back)

        counterLabel.textColor = .white
        counterLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        counterLabel.textAlignment = .center
        counterLabel.tag = 2
        topBar.addSubview(counterLabel)

        let menu = UIButton(type: .system)
        menu.setImage(UIImage(systemName: "ellipsis",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)),
                      for: .normal)
        menu.tintColor = .white
        menu.tag = 3
        menu.addTarget(self, action: #selector(menuTapped), for: .touchUpInside)
        topBar.addSubview(menu)

        guard post != nil else { return }

        bottomGradient.colors = [UIColor.clear.cgColor,
                                 UIColor.black.withAlphaComponent(0.55).cgColor]
        bottomBar.layer.insertSublayer(bottomGradient, at: 0)
        view.addSubview(bottomBar)

        for (button, icon, action) in [
            (likeButton, "heart", #selector(likeTapped)),
            (commentButton, "bubble.right", #selector(commentsTapped)),
            (shareButton, "arrowshape.turn.up.right", #selector(shareTapped))
        ] {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: icon,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))
            config.imagePadding = 6
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 12)
            config.baseForegroundColor = .white
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var updated = attrs
                updated.font = UIFont.systemFont(ofSize: 15)
                return updated
            }
            button.configuration = config
            button.addTarget(self, action: action, for: .touchUpInside)
            bottomBar.addSubview(button)
        }
    }

    private func layoutChrome() {
        let safe = view.safeAreaInsets
        let width = view.bounds.width

        let topHeight = safe.top + 48
        topBar.frame = CGRect(x: 0, y: 0, width: width, height: topHeight)
        topGradient.frame = topBar.bounds
        topBar.viewWithTag(1)?.frame = CGRect(x: 4, y: safe.top, width: 44, height: 44)
        topBar.viewWithTag(2)?.frame = CGRect(x: 60, y: safe.top, width: width - 120, height: 44)
        topBar.viewWithTag(3)?.frame = CGRect(x: width - 48, y: safe.top, width: 44, height: 44)

        guard post != nil else { return }
        let bottomHeight = safe.bottom + 56
        bottomBar.frame = CGRect(x: 0, y: view.bounds.height - bottomHeight,
                                 width: width, height: bottomHeight)
        bottomGradient.frame = bottomBar.bounds

        var x: CGFloat = 14
        for button in [likeButton, commentButton, shareButton] {
            let size = button.sizeThatFits(CGSize(width: 200, height: 40))
            button.frame = CGRect(x: x, y: 8, width: max(size.width, 44), height: 40)
            x = button.frame.maxX + 16
        }
    }

    private func setChromeAlpha(_ alpha: CGFloat) {
        topBar.alpha = alpha
        bottomBar.alpha = alpha
    }

    private func toggleChrome() {
        chromeHidden.toggle()
        UIView.animate(withDuration: 0.2) {
            self.setChromeAlpha(self.chromeHidden ? 0 : 1)
        }
    }

    private func refreshCounter() {
        counterLabel.text = "\(index + 1) из \(photos.count)"
    }

    private func refreshLikeButton() {
        guard let post, let likes = deps.likes else { return }
        let liked = likes.isLiked(post)
        likeButton.configuration?.image = UIImage(
            systemName: liked ? "heart.fill" : "heart",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        )
        likeButton.configuration?.baseForegroundColor = liked ? .systemRed : .white
        likeButton.configuration?.title = "\(likes.count(post))"
        commentButton.configuration?.title = "\(post.commentsCount)"
        shareButton.configuration?.title = "\(post.repostsCount)"
        view.setNeedsLayout()
    }

    // MARK: Действия

    @objc private func backTapped() { close() }

    @objc private func likeTapped() {
        guard let post, let likes = deps.likes, let settings = deps.settings else { return }
        likes.toggle(post, settings: settings)
        refreshLikeButton()
    }

    @objc private func commentsTapped() {
        guard let post,
              let settings = deps.settings, let likes = deps.likes,
              let player = deps.player, let downloads = deps.downloads,
              let library = deps.library else { return }
        let root = CommentsView(ownerID: post.ownerID, postID: post.postID)
            .environmentObject(settings)
            .environmentObject(likes)
            .environmentObject(player)
            .environmentObject(downloads)
            .environmentObject(library)
            .environmentObject(deps) // ссылки на фото в комментариях тоже открываются
        present(UIHostingController(rootView: root), animated: true)
    }

    @objc private func shareTapped() {
        guard let url = currentPhoto?.bestURL else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        present(activity, animated: true)
    }

    @objc private func menuTapped() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Скачать фото", style: .default) { [weak self] _ in
            PhotoActions.save(self?.currentPhoto?.bestURL) { note in self?.showToast(note) }
        })
        sheet.addAction(UIAlertAction(title: "Копировать", style: .default) { [weak self] _ in
            PhotoActions.copy(self?.currentPhoto?.bestURL) { note in self?.showToast(note) }
        })
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        sheet.popoverPresentationController?.sourceView = topBar
        present(sheet, animated: true)
    }

    private func showToast(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        label.textAlignment = .center
        label.layer.cornerRadius = 14
        label.clipsToBounds = true
        let size = label.sizeThatFits(CGSize(width: 300, height: 40))
        label.frame = CGRect(x: view.bounds.midX - (size.width + 32) / 2,
                             y: view.bounds.height - view.safeAreaInsets.bottom - 120,
                             width: size.width + 32, height: 34)
        label.alpha = 0
        view.addSubview(label)
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            UIView.animate(withDuration: 0.3, animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }
}

// MARK: - Страница галереи (зум/панорама/смахивание)

/// UIScrollView-страница: при мин. зуме горизонталь уходит пейджеру, вертикаль —
/// жесту закрытия; при зуме — обычная панорама (арбитраж как в Apple Photos).
@MainActor
private final class ZoomPageView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let photo: Photo
    var onSingleTap: (() -> Void)?
    var onDismissChanged: ((CGPoint) -> Void)?
    var onDismissEnded: ((CGPoint, CGFloat) -> Void)?

    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private var loadedURL: URL?

    var currentImage: UIImage? { imageView.image }

    init(photo: Photo) {
        self.photo = photo
        super.init(frame: .zero)

        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.bouncesZoom = true
        scroll.isScrollEnabled = false // при мин. зуме горизонталь → пейджеру
        addSubview(scroll)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(dismissPan(_:)))
        pan.delegate = self
        scroll.addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        // При мин. зуме страница = экран, contentMode fit сам центрирует картинку.
        if scroll.zoomScale <= scroll.minimumZoomScale + 0.001 {
            imageView.frame = bounds
            scroll.contentSize = bounds.size
        }
    }

    /// Кэш → мгновенно; иначе кадр ленты как замена + полный размер фоном.
    func load() {
        guard let url = photo.bestURL, loadedURL != url else { return }
        loadedURL = url
        let full: CGFloat = 2048

        if let ready = ImageCache.shared.image(for: url, maxPixelSize: full) {
            imageView.image = ready
            return
        }
        if let provisional = heroCachedImage(url) ?? heroCachedImage(photo.thumbURL) {
            imageView.image = provisional
        }
        Task { [weak self] in
            guard let data = try? await URLSession.shared.data(from: url).0,
                  let image = await ImagePipeline.downsample(data: data, maxPixelSize: full)
            else { return }
            ImageCache.shared.insert(image, for: url, maxPixelSize: full)
            await MainActor.run {
                guard let self, self.loadedURL == url else { return }
                self.imageView.image = image
            }
        }
    }

    // MARK: Зум

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Центрируем картинку, пока она меньше экрана.
        let bounds = scrollView.bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.width < bounds.width ? (bounds.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < bounds.height ? (bounds.height - frame.height) / 2 : 0
        imageView.frame = frame
        scrollView.isScrollEnabled = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
    }

    @objc private func singleTapped() { onSingleTap?() }

    @objc private func doubleTapped(_ gr: UITapGestureRecognizer) {
        if scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
            scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
        } else {
            let point = gr.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: scroll.bounds.width / scale,
                              height: scroll.bounds.height / scale)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
        }
    }

    // MARK: Смахивание для закрытия

    @objc private func dismissPan(_ gr: UIPanGestureRecognizer) {
        // Меряем в окне: сама страница едет за пальцем, и translation(in: self)
        // давал бы обратную связь и «дёрганье».
        let t = gr.translation(in: nil)
        switch gr.state {
        case .changed:
            onDismissChanged?(CGPoint(x: t.x, y: t.y))
        case .ended, .cancelled, .failed:
            onDismissEnded?(CGPoint(x: t.x, y: t.y), gr.velocity(in: nil).y)
        default:
            break
        }
    }

    /// Пан закрытия — ТОЛЬКО при мин. зуме и вертикальном движении.
    /// (override: у UIView есть одноимённый метод; он же служит реализацией делегата.)
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard scroll.zoomScale <= scroll.minimumZoomScale + 0.01 else { return false }
        let v = pan.velocity(in: nil)
        return abs(v.y) > abs(v.x)
    }
}

// MARK: - Действия с фото (сохранение/копирование)

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
