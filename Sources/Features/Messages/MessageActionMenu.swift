import UIKit

// MARK: - Хост контекст-слоя

/// Хост контекст-меню. Архитектура ПРОВЕРЕНА по исходникам Telegram-iOS
/// (Display/Navigation/NavigationController.swift:538-541): когда клавиатура видна,
/// Telegram МОНТИРУЕТ контейнер глобального оверлея (весь ContextController с его живым
/// блюром) ВНУТРЬ окна клавиатуры НАД клавишами (`keyboardWindow.addSubnode(...)`,
/// `zPosition = 1000`). Ничего не замораживается и не прячется: живой `UIVisualEffectView`
/// оверлея сэмплит клавиши (то же окно, ниже) И все нижние окна (переписка, навбар, поле
/// ввода) → ЕДИНЫЙ непрерывный блюр всего экрана. Клавиатура остаётся обычной живой частью
/// сцены; оверлей, лежа поверх неё в её же окне, перехватывает все касания.
/// Без клавиатуры — обычное своё окно поверх приложения.
@MainActor
final class MessageMenuWindow {
    static let shared = MessageMenuWindow()
    private var window: UIWindow?                 // путь «клавиатура закрыта»
    private var mountedController: UIViewController?  // strong ref при монтировании в окно клавы
    private var mountedView: UIView?

    var isPresented: Bool { window != nil || mountedView != nil }

    /// `keyboardTop` — верх клавиатуры в координатах экрана (.greatestFiniteMagnitude = закрыта).
    func present(_ controller: UIViewController, keyboardTop: CGFloat) {
        guard !isPresented else { return }

        // Клавиатура видна → как Telegram: контекст-слой ЦЕЛИКОМ в окно клавиатуры, над
        // клавишами. addSubview последним + zPosition — и рендер, и hit-test поверх клавиш:
        // клавиши на время меню естественно не получают касаний (никаких флагов).
        if keyboardTop < UIScreen.main.bounds.height, let kw = Self.findKeyboardWindow() {
            guard let v = controller.view else { return }
            // Рамка ВСЕГО экрана В КООРДИНАТАХ окна клавиатуры: НЕ полагаемся на то, что
            // окно клавиатуры полноэкранное с нулевым origin (Telegram ставит origin .zero
            // и размер главного лэйаута — то же самое, но неявно). После этого координаты
            // вью контроллера == координатам экрана, и рамка пузыря/панелей ложится точно.
            let screen = kw.screen
            let overlayFrame = kw.convert(screen.bounds, from: screen.coordinateSpace)
            v.frame = overlayFrame
            v.layer.zPosition = 1000
            kw.addSubview(v)

            #if DEBUG
            // Диагностика координатных пространств (симптом «текстура клавиатуры поверх
            // поля ввода»): сверить рамки окна клавиатуры, экрана и оверлея.
            print("[ContextMenu] screen.bounds=\(screen.bounds)")
            print("[ContextMenu] kw=\(NSStringFromClass(type(of: kw))) frame=\(kw.frame) bounds=\(kw.bounds) level=\(kw.windowLevel.rawValue)")
            print("[ContextMenu] overlayFrame(в координатах kw)=\(overlayFrame)")
            print("[ContextMenu] keyboardTop(экран)=\(keyboardTop)")
            for sub in kw.subviews {
                print("[ContextMenu] kw.subview \(NSStringFromClass(type(of: sub))) frame=\(sub.frame) z=\(sub.layer.zPosition)")
            }
            #endif

            mountedController = controller
            mountedView = v
            (controller as? ContextMenuController)?.hostDidPresent()
            return
        }

        // Клавиатуры нет → своё окно поверх приложения (живой блюр сэмплит нижние окна).
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        w.backgroundColor = .clear
        w.rootViewController = controller
        w.isHidden = false
        window = w
    }

    func dismiss() {
        mountedView?.removeFromSuperview()
        mountedView = nil
        mountedController = nil
        window?.isHidden = true
        window = nil
    }

    /// Окно клавиатуры. В `scene.windows` оно может не входить — добираем полный список
    /// окон приложения через KVC (эквивалент устаревшего `UIApplication.windows`).
    private static func findKeyboardWindow() -> UIWindow? {
        var all = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        if let extra = UIApplication.shared.value(forKey: "windows") as? [UIWindow] {
            for w in extra where !all.contains(w) { all.append(w) }
        }
        return all.last { NSStringFromClass(type(of: $0)).contains("RemoteKeyboardWindow") }
            ?? all.last { NSStringFromClass(type(of: $0)).contains("TextEffectsWindow") }
            ?? all.last { $0.windowLevel.rawValue >= 10_000_000 }
    }
}

// MARK: - Конфигурация контекст-меню

/// Всё, что нужно меню: рамка и снимок пузыря, реакции, права, колбэки.
struct ContextMenuConfig {
    let sourceFrame: CGRect      // рамка пузыря в координатах окна
    let snapshot: UIView?        // снимок пузыря как отрисован — пиксель-в-пиксель копия
    let isOut: Bool
    let emojis: [String]         // пусто = реакции выключены (тумблер отладки)
    let myReaction: String?
    let canEditDelete: Bool
    let keyboardTop: CGFloat
    let onReact: (String) -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
}

// MARK: - Контекст-слой (архитектура Telegram ContextUI)

/// Три независимых уровня одного слоя (как в ContextUI):
///  1. BACKDROP — ЕДИНЫЙ живой UIVisualEffectView + дим. Ничего не замораживается:
///     backdrop сэмплит ВСЁ, что скомпоновано ниже — клавиши (то же окно, ниже нас),
///     переписку, навбар и поле ввода (нижние окна) → один непрерывный размытый экран,
///     всё живое (каретка в поле ввода продолжает мигать — размытой).
///  2. LIFTED MESSAGE — снимок пузыря на точном месте оригинала, резкий, с тенью.
///     Оригинальную ячейку не двигаем и не масштабируем.
///  3. FLOATING CONTROLS — горизонтальная панель реакций + меню действий,
///     пружина от угла у пузыря; раскладка по ВСЕЙ высоте экрана — размытая клавиатура
///     просто фон, панели могут занимать её область (как в Telegram ContextUI).
final class ContextMenuController: UIViewController {
    private let config: ContextMenuConfig

    // 1. Фоновый слой.
    private let blur = UIVisualEffectView(effect: nil)   // блюр НАРАСТАЕТ в анимации
    private let dim = UIView()

    // 2. «Поднятое» сообщение.
    private let snapshotContainer = UIView()

    // 3. Плавающие контролы.
    private let reactionsContainer = UIView()
    private let actionsContainer = UIView()

    private var menuBelow = true
    private var didLayout = false
    private var didAnimateIn = false
    private var closing = false

    private let gap: CGFloat = 10
    private let actionsWidth: CGFloat = 250
    private let rowHeight: CGFloat = 44
    private let reactionCell: CGFloat = 40

    init(config: ContextMenuConfig) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Вызывается хостом после монтирования вью в окно клавиатуры (там нет viewDidAppear).
    func hostDidPresent() {
        view.layoutIfNeeded()   // раскладка панелей до анимации
        #if DEBUG
        print("[ContextMenu] controller.view frame=\(view.frame) bounds=\(view.bounds) safeArea=\(view.safeAreaInsets)")
        print("[ContextMenu] sourceFrame(окно чата)=\(config.sourceFrame) reactions=\(reactionsContainer.frame) actions=\(actionsContainer.frame)")
        #endif
        animateInIfNeeded()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // 1. Backdrop: единый живой блюр → дим.
        blur.frame = view.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(blur)
        dim.frame = view.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.08)
        dim.alpha = 0
        view.addSubview(dim)

        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backgroundTapped)))

        // 2. «Поднятая» копия сообщения — на точном месте оригинала, резкая, с тенью.
        snapshotContainer.frame = config.sourceFrame
        if let snap = config.snapshot {
            snap.frame = snapshotContainer.bounds
            snap.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshotContainer.addSubview(snap)
        }
        snapshotContainer.layer.shadowColor = UIColor.black.cgColor
        snapshotContainer.layer.shadowOpacity = 0
        snapshotContainer.layer.shadowRadius = 12
        snapshotContainer.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.addSubview(snapshotContainer)

        // 3. Контролы.
        buildReactions()
        buildActions()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !didLayout else { return }
        didLayout = true
        layoutPanels()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animateInIfNeeded()   // путь «своё окно» (без клавиатуры)
    }

    private func animateInIfNeeded() {
        guard !didAnimateIn else { return }
        didAnimateIn = true
        animateIn()
    }

    // MARK: Панель реакций (горизонтальная)

    private func buildReactions() {
        guard !config.emojis.isEmpty else { reactionsContainer.isHidden = true; return }

        let bar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        bar.layer.cornerRadius = 25
        bar.clipsToBounds = true

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: bar.contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.contentView.centerYAnchor)
        ])

        for emoji in config.emojis {
            let button = UIButton(type: .custom)
            button.setTitle(emoji, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 30)
            if emoji == config.myReaction {
                button.backgroundColor = OVKUI.primary.withAlphaComponent(0.18)
                button.layer.cornerRadius = reactionCell / 2
            }
            button.widthAnchor.constraint(equalToConstant: reactionCell).isActive = true
            button.heightAnchor.constraint(equalToConstant: reactionCell).isActive = true
            // Лёгкое «нажатие» эмодзи.
            button.addAction(UIAction { _ in
                UIView.animate(withDuration: 0.15) { button.transform = CGAffineTransform(scaleX: 1.25, y: 1.25) }
            }, for: .touchDown)
            button.addAction(UIAction { [weak self] _ in
                self?.config.onReact(emoji)
                self?.close()
            }, for: .touchUpInside)
            button.addAction(UIAction { _ in
                UIView.animate(withDuration: 0.15) { button.transform = .identity }
            }, for: [.touchUpOutside, .touchCancel])
            stack.addArrangedSubview(button)
        }

        bar.translatesAutoresizingMaskIntoConstraints = false
        reactionsContainer.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: reactionsContainer.topAnchor),
            bar.bottomAnchor.constraint(equalTo: reactionsContainer.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: reactionsContainer.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: reactionsContainer.trailingAnchor)
        ])
        reactionsContainer.layer.shadowColor = UIColor.black.cgColor
        reactionsContainer.layer.shadowOpacity = 0.18
        reactionsContainer.layer.shadowRadius = 16
        reactionsContainer.layer.shadowOffset = CGSize(width: 0, height: 6)
        view.addSubview(reactionsContainer)
    }

    private var reactionsSize: CGSize {
        guard !config.emojis.isEmpty else { return .zero }
        let count = CGFloat(config.emojis.count)
        return CGSize(width: count * reactionCell + (count - 1) * 2 + 12, height: 50)
    }

    // MARK: Список действий (нативный вид)

    private func buildActions() {
        let box = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        box.layer.cornerRadius = 13
        box.layer.cornerCurve = .continuous
        box.clipsToBounds = true

        var rows: [UIView] = [makeRow(title: "Копировать", icon: "doc.on.doc", destructive: false, action: config.onCopy)]
        if config.canEditDelete {
            rows.append(makeRow(title: "Изменить", icon: "pencil", destructive: false, action: config.onEdit))
            rows.append(makeRow(title: "Удалить", icon: "trash", destructive: true, action: config.onDelete))
        }

        let stack = UIStackView()
        stack.axis = .vertical
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let hairline = UIView()
                hairline.backgroundColor = UIColor.label.withAlphaComponent(0.15)
                hairline.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
                stack.addArrangedSubview(hairline)
            }
            stack.addArrangedSubview(row)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.contentView.trailingAnchor)
        ])

        box.translatesAutoresizingMaskIntoConstraints = false
        actionsContainer.addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: actionsContainer.topAnchor),
            box.bottomAnchor.constraint(equalTo: actionsContainer.bottomAnchor),
            box.leadingAnchor.constraint(equalTo: actionsContainer.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: actionsContainer.trailingAnchor)
        ])
        actionsContainer.layer.shadowColor = UIColor.black.cgColor
        actionsContainer.layer.shadowOpacity = 0.18
        actionsContainer.layer.shadowRadius = 16
        actionsContainer.layer.shadowOffset = CGSize(width: 0, height: 6)
        view.addSubview(actionsContainer)
    }

    private var actionsHeight: CGFloat {
        let rows: CGFloat = config.canEditDelete ? 3 : 1
        return rows * rowHeight + (rows - 1) * (1.0 / UIScreen.main.scale)
    }

    private func makeRow(title: String, icon: String, destructive: Bool, action: @escaping () -> Void) -> UIView {
        let button = MenuRowButton()
        button.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 17)
        label.textColor = destructive ? .systemRed : .label
        let image = UIImageView(image: UIImage(systemName: icon))
        image.tintColor = destructive ? .systemRed : .label
        image.contentMode = .scaleAspectFit
        for v in [label, image] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false
            button.addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            image.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16),
            image.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 22)
        ])
        button.addAction(UIAction { [weak self] _ in
            action()
            self?.close()
        }, for: .touchUpInside)
        return button
    }

    // MARK: Раскладка (сообщение НЕ двигаем; контролы — по ВСЕЙ высоте экрана)
    //
    // Клавиатура — НЕ ограничение раскладки, а часть размытого фона (как в Telegram
    // ContextUI): контекст-слой смонтирован НАД окном клавиатуры, поэтому панели могут
    // спокойно занимать её область. Клампим только к краям экрана/safe area.

    private func layoutPanels() {
        let f = config.sourceFrame
        let bottomBound = view.bounds.height - view.safeAreaInsets.bottom - 8
        let topBound = view.safeAreaInsets.top + 8
        #if DEBUG
        print("[ContextMenu] bottomBound(экран/safe area)=\(bottomBound)")
        #endif

        let rSize = reactionsSize
        let hasReactions = rSize != .zero

        // Меню под сообщением, если влезает в экран; иначе — над ним (вместе с реакциями).
        menuBelow = f.maxY + gap + actionsHeight <= bottomBound
        var menuY = menuBelow ? f.maxY + gap : f.minY - gap - actionsHeight
        var reactionsY = menuBelow ? f.minY - gap - rSize.height
                                   : f.minY - gap - actionsHeight - gap - rSize.height
        reactionsY = max(reactionsY, topBound)
        if !menuBelow, hasReactions {
            menuY = max(menuY, reactionsY + rSize.height + gap)
        }

        let x = { (w: CGFloat) in
            self.config.isOut ? self.view.bounds.width - 12 - w : 12
        }
        if hasReactions {
            reactionsContainer.frame = CGRect(x: x(rSize.width), y: reactionsY,
                                              width: rSize.width, height: rSize.height)
        }
        actionsContainer.frame = CGRect(x: x(actionsWidth), y: menuY,
                                        width: actionsWidth, height: actionsHeight)
    }

    // MARK: Анимации

    private func animateIn() {
        let corner = CGPoint(x: config.isOut ? 1 : 0, y: 1)
        setAnchor(corner, for: reactionsContainer)
        setAnchor(CGPoint(x: corner.x, y: menuBelow ? 0 : 1), for: actionsContainer)
        for panel in [reactionsContainer, actionsContainer] {
            panel.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            panel.alpha = 0
        }

        // Единый блюр НАРАСТАЕТ (анимация effect nil → material — честное прогрессивное
        // размытие замороженного кадра, как в ContextUI), контролы пружинят.
        UIView.animate(withDuration: 0.38, delay: 0,
                       usingSpringWithDamping: 0.8, initialSpringVelocity: 0.3,
                       options: [.allowUserInteraction]) {
            self.blur.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            self.dim.alpha = 1
            for panel in [self.reactionsContainer, self.actionsContainer] {
                panel.transform = .identity
                panel.alpha = 1
            }
        }

        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0
        shadow.toValue = 0.18
        shadow.duration = 0.3
        snapshotContainer.layer.add(shadow, forKey: "shadow")
        snapshotContainer.layer.shadowOpacity = 0.18
    }

    private func close() {
        guard !closing else { return }
        closing = true
        // Обратная анимация: блюр сходит до резкого замороженного кадра (там клавиатура
        // на своём месте), затем в одном коммите кадр подменяется живым экраном.
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
            self.blur.effect = nil
            self.dim.alpha = 0
            self.snapshotContainer.layer.shadowOpacity = 0
            for panel in [self.reactionsContainer, self.actionsContainer] {
                panel.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
                panel.alpha = 0
            }
        } completion: { _ in
            MessageMenuWindow.shared.dismiss()
        }
    }

    @objc private func backgroundTapped() { close() }

    /// Смена anchorPoint без визуального скачка (пересчёт position).
    private func setAnchor(_ anchor: CGPoint, for v: UIView) {
        let newPoint = CGPoint(x: v.bounds.width * anchor.x, y: v.bounds.height * anchor.y)
        let oldPoint = CGPoint(x: v.bounds.width * v.layer.anchorPoint.x,
                               y: v.bounds.height * v.layer.anchorPoint.y)
        var position = v.layer.position
        position.x += newPoint.x - oldPoint.x
        position.y += newPoint.y - oldPoint.y
        v.layer.anchorPoint = anchor
        v.layer.position = position
    }
}

/// Строка меню с подсветкой при нажатии — как в системном контекст-меню.
private final class MenuRowButton: UIButton {
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? UIColor.label.withAlphaComponent(0.12) : .clear }
    }
}
