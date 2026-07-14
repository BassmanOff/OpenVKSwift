import SwiftUI
import UIKit
import Combine

/// SwiftUI-мост: встраивает UIKit-контроллер диалога (список + поле ввода + клавиатура).
struct ChatScreen: UIViewControllerRepresentable {
    let model: ChatViewModel
    let peerID: Int
    @EnvironmentObject private var settings: AppSettings
    var onToast: (String) -> Void
    var onOpenURL: (URL) -> Void
    var onOpenImage: (URL, UIView) -> Void
    var onAttach: () -> Void

    func makeUIViewController(context: Context) -> ChatScreenController {
        ChatScreenController(model: model, settings: settings, peerID: peerID,
                             onToast: onToast, onOpenURL: onOpenURL, onOpenImage: onOpenImage,
                             onAttach: onAttach)
    }

    func updateUIViewController(_ controller: ChatScreenController, context: Context) {
        controller.onToast = onToast
        controller.onOpenURL = onOpenURL
        controller.onOpenImage = onOpenImage
        controller.onAttach = onAttach
    }
}

/// UIKit-экран переписки (архитектура мессенджеров: Telegram и др.).
///
/// • ИНВЕРТИРОВАННЫЙ UICollectionView (transform scaleY:-1, ячейки развёрнуты обратно,
///   данные новейшими вперёд): offset 0 == низ переписки → первый кадр ВСЕГДА корректен,
///   короткая переписка прижата к низу, «прокрутки к последнему» не существует в принципе.
/// • Diffable data source: стабильные анимации вставки/удаления, reconfigure для смены
///   статусов/реакций без пересоздания ячеек.
/// • Клавиатура — НАТИВНО: keyboardWillChangeFrame → констрейнт нижней панели + анимация
///   с длительностью/кривой самой клавиатуры. Инвертированный список при сжатии сам
///   оставляет последнее сообщение на виду.
@MainActor
final class ChatScreenController: UIViewController {
    private let model: ChatViewModel
    private let settings: AppSettings
    private let peerID: Int
    var onToast: (String) -> Void
    var onOpenURL: (URL) -> Void
    var onOpenImage: (URL, UIView) -> Void
    /// Тап по «скрепке» — SwiftUI-слой показывает предупреждение/пикер (см. ChatView).
    var onAttach: () -> Void

    // Список
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    /// «Вниз» (как в Telegram) — появляется, когда прокрутили вверх дальше чем на экран.
    private let scrollToBottomButton = UIButton(type: .system)
    private var scrollToBottomVisible = false
    private var rowsByID: [String: ChatViewModel.ChatRow] = [:]
    /// Подпись содержимого строки (текст/статус/реакции) — reconfigure только реально
    /// изменившихся строк, иначе каждый publish модели перерисовывал бы все ячейки (мигание).
    private var rowSignatures: [String: Int] = [:]
    /// Кэш высот по id строки: высота меряется ОДИН раз шаблонной ячейкой и не меняется,
    /// пока не изменилось содержимое строки (инвалидация — вместе с подписью).
    private var heightCache: [String: CGFloat] = [:]
    private var heightCacheWidth: CGFloat = 0
    /// Шаблонная ячейка для замера высот — та же раскладка, что у живых ячеек.
    private let sizingCell = MessageCell(frame: CGRect(x: 0, y: 0, width: 320, height: 100))

    // Панель ввода
    private let inputBar = UIView()
    private let editBanner = UIStackView()
    private let textBackground = UIView()
    private let textView = SelfSizingTextView()
    private let placeholderLabel = UILabel()
    private let attachButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private var editingID: Int?

    // Клавиатура
    private var inputBottom: NSLayoutConstraint!
    private var keyboardTopScreen: CGFloat = .greatestFiniteMagnitude

    // Пустое состояние / загрузка
    private let emptyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var modelSink: AnyCancellable?
    private var reloadScheduled = false

    init(model: ChatViewModel, settings: AppSettings, peerID: Int,
         onToast: @escaping (String) -> Void, onOpenURL: @escaping (URL) -> Void,
         onOpenImage: @escaping (URL, UIView) -> Void, onAttach: @escaping () -> Void) {
        self.model = model
        self.settings = settings
        self.peerID = peerID
        self.onToast = onToast
        self.onOpenURL = onOpenURL
        self.onOpenImage = onOpenImage
        self.onAttach = onAttach
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = OVKUI.background
        buildCollection()
        buildInputBar()
        buildStateViews()
        layoutViews()

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )

        // Модель — источник истины. objectWillChange стреляет ДО мутации, поэтому
        // перечитываем состояние асинхронно (после применения) и склеиваем всплески.
        modelSink = model.objectWillChange.sink { [weak self] _ in
            guard let self, !self.reloadScheduled else { return }
            self.reloadScheduled = true
            DispatchQueue.main.async {
                self.reloadScheduled = false
                self.reloadFromModel()
            }
        }
        reloadFromModel()

        // Черновик пережил пересоздание экрана (модель живёт в SwiftUI-обёртке).
        if !model.text.isEmpty {
            textView.text = model.text
            textView.invalidateIntrinsicContentSize()
            textDidChangeUI()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if MessageMenuWindow.shared.isPresented { MessageMenuWindow.shared.dismiss() }
    }

    // MARK: Сборка интерфейса

    private func buildCollection() {
        let layout = UICollectionViewFlowLayout()
        // БЕЗ self-sizing (estimatedItemSize намеренно НЕ ставим): с automaticSize любая
        // инвалидация (apply снапшота при пагинации) сбрасывала высоты НЕВИДИМЫХ ячеек к
        // оценкам → contentSize «плавал» (в логах даже УМЕНЬШАЛСЯ при добавлении строк),
        // список прыгал. Высоты отдаёт sizeForItemAt: меряются один раз шаблонной ячейкой,
        // кэшируются по id → раскладка детерминирована, contentSize при догрузке ТОЛЬКО растёт.
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)  // низ = начало прокрутки
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        collectionView.showsVerticalScrollIndicator = false             // в отражённом виде мешает
        collectionView.scrollsToTop = false
        collectionView.alwaysBounceVertical = true
        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: MessageCell.reuseID)
        collectionView.delegate = self   // willDisplay → пагинация старой истории
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) {
            [weak self] cv, indexPath, id in
            let cell = cv.dequeueReusableCell(withReuseIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
            if let self, let row = self.rowsByID[id] {
                self.configure(cell, row: row, width: cv.bounds.width)
            }
            return cell
        }

        // Тап по переписке закрывает клавиатуру (как в Telegram). cancelsTouchesInView=false —
        // не мешает кнопкам чипов и ссылкам.
        let tap = UITapGestureRecognizer(target: self, action: #selector(listTapped))
        tap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(tap)
    }

    private func buildInputBar() {
        inputBar.backgroundColor = OVKUI.card
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inputBar)

        // Баннер режима правки.
        let pencil = UIImageView(image: UIImage(systemName: "pencil"))
        pencil.tintColor = OVKUI.primary
        pencil.setContentHuggingPriority(.required, for: .horizontal)
        let editLabel = UILabel()
        editLabel.text = "Редактирование"
        editLabel.font = .preferredFont(forTextStyle: .caption1)
        editLabel.textColor = OVKUI.textSecondary
        let cancelEdit = UIButton(type: .system)
        cancelEdit.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        cancelEdit.tintColor = OVKUI.textSecondary
        cancelEdit.addAction(UIAction { [weak self] _ in self?.cancelEditing() }, for: .touchUpInside)
        let bannerSpacer = UIView()
        editBanner.axis = .horizontal
        editBanner.spacing = 8
        editBanner.alignment = .center
        for v in [pencil, editLabel, bannerSpacer, cancelEdit] { editBanner.addArrangedSubview(v) }
        editBanner.isHidden = true

        // Поле ввода.
        textBackground.backgroundColor = OVKUI.background
        textBackground.layer.cornerRadius = 18
        textView.maxHeight = 120
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        textBackground.addSubview(textView)

        placeholderLabel.text = "Сообщение…"
        placeholderLabel.font = textView.font
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textBackground.addSubview(placeholderLabel)

        let symbol = UIImage.SymbolConfiguration(pointSize: 22)
        attachButton.setImage(UIImage(systemName: "paperclip", withConfiguration: symbol), for: .normal)
        attachButton.tintColor = OVKUI.textSecondary
        attachButton.addAction(UIAction { [weak self] _ in self?.onAttach() }, for: .touchUpInside)

        sendButton.setImage(UIImage(systemName: "paperplane.fill", withConfiguration: symbol), for: .normal)
        sendButton.addAction(UIAction { [weak self] _ in self?.sendTapped() }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [attachButton, textBackground, sendButton])
        row.axis = .horizontal
        row.spacing = 4
        row.alignment = .bottom

        let barStack = UIStackView(arrangedSubviews: [editBanner, row])
        barStack.axis = .vertical
        barStack.spacing = 6
        barStack.translatesAutoresizingMaskIntoConstraints = false
        inputBar.addSubview(barStack)

        NSLayoutConstraint.activate([
            barStack.topAnchor.constraint(equalTo: inputBar.topAnchor, constant: 5),
            barStack.bottomAnchor.constraint(equalTo: inputBar.bottomAnchor, constant: -5),
            barStack.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor, constant: 6),
            barStack.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor, constant: -6),

            attachButton.widthAnchor.constraint(equalToConstant: 38),
            attachButton.heightAnchor.constraint(equalToConstant: 38),
            sendButton.widthAnchor.constraint(equalToConstant: 38),
            sendButton.heightAnchor.constraint(equalToConstant: 38),

            textBackground.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            textView.topAnchor.constraint(equalTo: textBackground.topAnchor),
            textView.bottomAnchor.constraint(equalTo: textBackground.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: textBackground.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: textBackground.trailingAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: textBackground.leadingAnchor, constant: 12),
            placeholderLabel.topAnchor.constraint(equalTo: textBackground.topAnchor, constant: 8)
        ])

        updateSendButton()
    }

    private func buildStateViews() {
        emptyLabel.text = "Напишите первое сообщение"
        emptyLabel.textColor = OVKUI.textSecondary
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        scrollToBottomButton.backgroundColor = OVKUI.card
        scrollToBottomButton.tintColor = OVKUI.primary
        scrollToBottomButton.setImage(
            UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)),
            for: .normal
        )
        scrollToBottomButton.layer.cornerRadius = 20
        scrollToBottomButton.layer.shadowColor = UIColor.black.cgColor
        scrollToBottomButton.layer.shadowOpacity = 0.15
        scrollToBottomButton.layer.shadowRadius = 4
        scrollToBottomButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        scrollToBottomButton.addAction(UIAction { [weak self] _ in self?.scrollToBottomTapped() }, for: .touchUpInside)
        scrollToBottomButton.alpha = 0
        scrollToBottomButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollToBottomButton)
    }

    private func layoutViews() {
        inputBottom = inputBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBottom,

            emptyLabel.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),

            scrollToBottomButton.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor, constant: -16),
            scrollToBottomButton.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor, constant: -12),
            scrollToBottomButton.widthAnchor.constraint(equalToConstant: 40),
            scrollToBottomButton.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    // MARK: Данные

    private func reloadFromModel() {
        // Новейшие вперёд — порядок инвертированного списка.
        let rows = Array(model.rows.reversed())
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        let ids = rows.map(\.id)
        let oldIDs = dataSource.snapshot().itemIdentifiers
        let oldIDSet = Set(oldIDs)

        // reconfigure — ТОЛЬКО строки, чьё содержимое реально изменилось (модель публикует
        // и идентичные состояния: кэш → сеть с теми же данными, каждый poll и т.п.).
        var newSignatures: [String: Int] = [:]
        var changed: [String] = []
        for row in rows {
            let sig = signature(for: row)
            newSignatures[row.id] = sig
            if oldIDSet.contains(row.id), rowSignatures[row.id] != sig {
                changed.append(row.id)
            }
        }
        rowSignatures = newSignatures

        // Изменившееся содержимое могло сменить высоту (правка текста, чипы реакций) —
        // сбрасываем кэш высот ТОЛЬКО для этих строк; остальные высоты неприкосновенны.
        for id in changed { heightCache.removeValue(forKey: id) }
        if heightCache.count > ids.count {
            let idSet = Set(ids)
            heightCache = heightCache.filter { idSet.contains($0.key) }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        snapshot.reconfigureItems(changed)

        let structuralChange = ids != oldIDs
        // Пагинация = ЧИСТОЕ добавление старой истории в КОНЕЦ снапшота (визуальный верх):
        // прежние id на прежних индексах, новое — только в хвосте. Новое сообщение — это
        // вставка В НАЧАЛО, под этот паттерн не подпадает → анимации вставки сохраняются.
        let isOlderAppend = structuralChange && !oldIDs.isEmpty
            && ids.count > oldIDs.count && Array(ids.prefix(oldIDs.count)) == oldIDs

        #if DEBUG
        if structuralChange {
            print("[Snapshot] \(debugNow()) rows \(oldIDs.count)→\(ids.count), changed=\(changed.count), olderAppend=\(isOlderAppend)")
        }
        #endif

        if isOlderAppend {
            applyOlderAppend(snapshot)
        } else {
            // Анимация — только для НАСТОЯЩИХ структурных изменений уже показанного списка
            // (новое/удалённое сообщение). Первое наполнение (кэш) и обновления статусов —
            // БЕЗ анимации: иначе весь список «мигал» при открытии переписки.
            let animate = structuralChange && !oldIDs.isEmpty && view.window != nil
            dataSource.apply(snapshot, animatingDifferences: animate) {
                #if DEBUG
                if structuralChange {
                    print("[UICollectionView] \(debugNow()) применено: items=\(ids.count)")
                }
                #endif
            }
        }

        // Высоты — из sizeForItemAt: изменившимся строкам нужна переraskладка явно.
        if !changed.isEmpty {
            #if DEBUG
            print("[LayoutDebug] invalidation reason: изменилось содержимое строк (\(changed.count))")
            #endif
            collectionView.collectionViewLayout.invalidateLayout()
        }

        // Пустое состояние / спиннер.
        let empty = rows.isEmpty
        emptyLabel.isHidden = !(empty && !model.isLoading && model.errorMessage == nil)
        if empty && model.isLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    /// Применение страницы СТАРОЙ истории с ЯКОРЕМ: видимое сообщение остаётся ровно на
    /// том же месте экрана. Сам append в конец инвертированного списка offset не двигает,
    /// но flow layout с automaticSize при инвалидации ПЕРЕОЦЕНИВАЕТ высоты невидимых ячеек
    /// (сброс к estimated) → кадры существующих строк «плывут» — тот самый прыжок. Якорь
    /// компенсирует ЛЮБОЙ дрейф: запоминаем экранную позицию видимой строки до apply и
    /// восстанавливаем после. Без анимации (batch-апдейты + self-sizing и есть источник
    /// инвалидации; свежие строки всё равно за экраном).
    private func applyOlderAppend(_ snapshot: NSDiffableDataSourceSnapshot<Int, String>) {
        // Якорь — первая видимая строка (при чистом append индексы существующих не меняются).
        let anchorPath = collectionView.indexPathsForVisibleItems.min()
        let anchorFrameBefore = anchorPath.flatMap { collectionView.layoutAttributesForItem(at: $0)?.frame }
        let anchorScreenY = anchorFrameBefore.map { $0.minY - collectionView.contentOffset.y }
        let oldSize = collectionView.contentSize
        let oldOffset = collectionView.contentOffset

        #if DEBUG
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        print("[LayoutDebug] visible indexPaths: \(visible.map(\.item))")
        print("[LayoutDebug] visible frames: \(visible.compactMap { collectionView.layoutAttributesForItem(at: $0)?.frame })")
        print("[LayoutDebug] contentSize before: \(oldSize.height)")
        print("[LayoutDebug] invalidation reason: append страницы старой истории")
        #endif

        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.layoutIfNeeded()   // финальный проход раскладки: высоты детерминированы,
                                          // после него кадры больше не меняются

        if let anchorPath, let anchorScreenY,
           let attr = collectionView.layoutAttributesForItem(at: anchorPath) {
            let target = attr.frame.minY - anchorScreenY
            // Трогаем offset ТОЛЬКО при реальном дрейфе — иначе прервали бы инерцию скролла.
            if abs(target - collectionView.contentOffset.y) > 0.5 {
                collectionView.contentOffset.y = target
            }
            #if DEBUG
            print("[LayoutDebug] anchor index: \(anchorPath.item)")
            print("[LayoutDebug] anchor frame before: \(anchorFrameBefore ?? .zero)")
            print("[LayoutDebug] anchor frame after: \(attr.frame)")
            #endif
        }
        #if DEBUG
        print("[LayoutDebug] contentSize after: \(collectionView.contentSize.height)")
        print("[LayoutDebug] final contentOffset: \(collectionView.contentOffset.y)")
        print("[Pagination] после: items=\(snapshot.numberOfItems) contentSize=\(oldSize.height)→\(collectionView.contentSize.height) offset=\(oldOffset.y)→\(collectionView.contentOffset.y)")
        #endif
    }

    /// Подпись видимого содержимого строки: всё, что влияет на отрисовку ячейки.
    private func signature(for row: ChatViewModel.ChatRow) -> Int {
        var h = Hasher()
        switch row {
        case .message(let m):
            h.combine(m.id)
            h.combine(m.text)
            h.combine(m.isOut)
            h.combine(m.date)
            h.combine(m.isOut && m.id <= model.outRead)        // прочитанность (галочки)
            if let reacts = model.reactions[m.id] {
                for (uid, r) in reacts.sorted(by: { $0.key < $1.key }) {
                    h.combine(uid)
                    h.combine(r.emoji)
                }
            }
        case .pending(let p):
            h.combine(p.id)
            h.combine(p.failed)
        }
        return h.finalize()
    }

    private func configure(_ cell: MessageCell, row: ChatViewModel.ChatRow, width: CGFloat) {
        let myID = settings.userID ?? 0
        switch row {
        case .message(let m):
            let status: MessageDelivery? = m.isOut ? (m.id <= model.outRead ? .read : .sent) : nil
            cell.configure(text: m.text, date: m.date, isOut: m.isOut, status: status,
                           reactions: reactionGroups(model.reactions[m.id], myID: myID), width: width)
            cell.onLongPress = { [weak self, weak cell] in self?.presentMenu(message: m, cell: cell) }
            cell.onReact = { [weak self] emoji in
                guard let self else { return }
                Task { await self.model.react(targetID: m.id, emoji: emoji, peerID: self.peerID, settings: self.settings) }
            }
        case .pending(let p):
            cell.configure(text: p.text, date: p.date, isOut: true,
                           status: p.failed ? .failed : .sending, reactions: [], width: width)
            cell.onLongPress = nil
            cell.onReact = nil
        }
        cell.onOpenURL = { [weak self] url in self?.onOpenURL(url) }
        cell.onOpenImage = { [weak self] url, view in self?.onOpenImage(url, view) }
    }

    // MARK: Клавиатура
    //
    // Уведомление — только ТРИГГЕР и источник длительности/кривой. Позиция считается
    // СИНХРОННО в том же обработчике по реальной иерархии клавиатуры: `UIInputSetHostView`
    // (клавиши + панель подсказок QuickType), рамку которой уведомление может не учитывать.
    // Приём Telegram (WindowContent.swift:542-544: поправка рамки реальным keyboardView).
    // РОВНО ОДНА анимация на уведомление — никаких отложенных доводок.

    @objc private func keyboardChanged(_ note: Notification) {
        guard view.window != nil,
              let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7

        let (overlap, topScreen) = keyboardOverlap(endFrame: end)
        keyboardTopScreen = topScreen ?? .greatestFiniteMagnitude
        inputBottom.constant = -overlap
        #if DEBUG
        print("[KeyboardLayout] final inputBottom=\(-overlap) (в той же анимации)")
        #endif

        UIView.animate(withDuration: duration, delay: 0,
                       options: [UIView.AnimationOptions(rawValue: curve << 16),
                                 .beginFromCurrentState, .allowUserInteraction]) {
            self.view.layoutIfNeeded()
        }
    }

    /// (перекрытие клавиатурой в координатах нашего вью, верх клавиатуры на экране или nil).
    /// Замер host-вью — СИНХРОННО, в момент уведомления. Поправка принимается только в
    /// «полосе доверия» (не выше рамки уведомления больше, чем на высоту строки подсказок):
    /// защита от устаревшей геометрии host-вью в момент старта анимации.
    private func keyboardOverlap(endFrame: CGRect) -> (overlap: CGFloat, topScreen: CGFloat?) {
        let screenH = UIScreen.main.bounds.height
        #if DEBUG
        print("[KeyboardLayout] notification keyboard frame=\(endFrame)")
        #endif
        guard endFrame.minY < screenH else {
            #if DEBUG
            print("[KeyboardLayout] UIInputSetHostView=клавиатура скрывается — замер не нужен")
            #endif
            return (0, nil)
        }
        var top = endFrame.minY
        if let host = Self.findKeyboardHostView(), host.bounds.height > 0 {
            // Окно клавиатуры полноэкранное → координаты её окна == экранным.
            let hostFrame = host.convert(host.bounds, to: nil)
            #if DEBUG
            print("[KeyboardLayout] measured UIInputSetHostView frame=\(hostFrame)")
            #endif
            let hostTop = hostFrame.minY
            // Доверяем замеру только как поправке «на строку подсказок» (≤80pt выше
            // уведомления) — стойкость к недоанимированной/устаревшей рамке host-вью.
            if hostTop < top, hostTop > top - 80 { top = hostTop }
        } else {
            #if DEBUG
            print("[KeyboardLayout] UIInputSetHostView не найдена — используем рамку уведомления")
            #endif
        }
        // Считаем в ЭКРАННЫХ координатах: offset = высота экрана − верх клавиатуры.
        // НЕ через view.bounds/convert: на момент уведомления у вью ещё СТАРЫЙ низ (над
        // таб-баром), а при видимой клавиатуре SwiftUI убирает нижний inset и низ вью
        // совпадает с низом экрана — расчёт от старых bounds оставлял бар ниже на величину
        // этого inset'а (то самое «двойное вычитание» ~46pt). Констрейнт двигает ВЕСЬ
        // инпут-бар от низа вью, поэтому экранная формула ставит его ровно на top.
        return (max(0, screenH - top), top)
    }

    /// `UIInputSetHostView` — реальная область клавиатуры (клавиши + подсказки) в её окне.
    /// Окно клавиатуры может не входить в scene.windows — добираем полный список через KVC.
    private static func findKeyboardHostView() -> UIView? {
        var all = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        if let extra = UIApplication.shared.value(forKey: "windows") as? [UIWindow] {
            for w in extra where !all.contains(w) { all.append(w) }
        }
        let kw = all.last { NSStringFromClass(type(of: $0)).contains("RemoteKeyboardWindow") }
            ?? all.last { NSStringFromClass(type(of: $0)).contains("TextEffectsWindow") }
        guard let kw else { return nil }
        var host: UIView?
        func walk(_ v: UIView) {
            if NSStringFromClass(type(of: v)).contains("InputSetHostView") { host = v; return }
            for sub in v.subviews where host == nil { walk(sub) }
        }
        for sub in kw.subviews where host == nil { walk(sub) }
        return host
    }

    @objc private func listTapped() {
        // Отпускание long-press тоже распознаётся как тап — меню не должно ронять клавиатуру.
        guard !MessageMenuWindow.shared.isPresented else { return }
        view.endEditing(true)
    }

    // MARK: Отправка / правка

    private func sendTapped() {
        let content = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        if let id = editingID {
            cancelEditing()
            Task { await model.edit(messageID: id, newText: content, peerID: peerID, settings: settings) }
        } else {
            textView.text = ""
            textView.invalidateIntrinsicContentSize()
            textDidChangeUI()
            model.text = content
            // Клавиатуру не закрываем — удобно писать дальше (как в Telegram).
            Task { await model.send(peerID: peerID, settings: settings) }
        }
    }

    private func scrollToBottomTapped() {
        // Инвертированный список: -contentInset.top — штатная позиция «внизу» (не 0),
        // как в обычном UIScrollView, отдыхающем у верхней границы контента.
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: true)
    }

    private func beginEditing(_ message: Message) {
        editingID = message.id
        editBanner.isHidden = false
        attachButton.isHidden = true
        model.text = message.text
        textView.text = message.text
        textView.invalidateIntrinsicContentSize()
        textDidChangeUI()
        textView.becomeFirstResponder()
    }

    /// Выход из режима правки — с очисткой поля (крестик на баннере и после сохранения).
    private func cancelEditing() {
        editingID = nil
        editBanner.isHidden = true
        attachButton.isHidden = false
        textView.text = ""
        textView.invalidateIntrinsicContentSize()
        model.text = ""
        textDidChangeUI()
    }

    private func updateSendButton() {
        let canSend = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let symbol = UIImage.SymbolConfiguration(pointSize: 22)
        sendButton.setImage(
            UIImage(systemName: editingID != nil ? "checkmark.circle.fill" : "paperplane.fill",
                    withConfiguration: symbol),
            for: .normal
        )
        sendButton.isEnabled = canSend
        sendButton.tintColor = canSend ? OVKUI.primary : OVKUI.textSecondary
    }

    private func textDidChangeUI() {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateSendButton()
    }

    // MARK: Меню действий (long-press)

    private func presentMenu(message m: Message, cell: MessageCell?) {
        guard !MessageMenuWindow.shared.isPresented,
              let cell, let frame = cell.bubbleFrameInWindow() else { return }
        let myID = settings.userID ?? 0
        let config = ContextMenuConfig(
            sourceFrame: frame,
            snapshot: cell.bubbleSnapshot(),
            isOut: m.isOut,
            emojis: settings.enableCustomReactions ? HiddenReaction.palette : [],
            myReaction: model.reactions[m.id]?[myID]?.emoji,
            canEditDelete: m.isOut,
            keyboardTop: keyboardTopScreen,
            onReact: { [weak self] emoji in
                guard let self else { return }
                Task { await self.model.react(targetID: m.id, emoji: emoji, peerID: self.peerID, settings: self.settings) }
            },
            onCopy: { UIPasteboard.general.string = m.text },
            onEdit: { [weak self] in self?.beginEditing(m) },
            onDelete: { [weak self] in
                guard let self else { return }
                Task { await self.model.delete(messageID: m.id, peerID: self.peerID, settings: self.settings) }
            }
        )
        MessageMenuWindow.shared.present(ContextMenuController(config: config),
                                         keyboardTop: keyboardTopScreen)
    }
}

extension ChatScreenController: UICollectionViewDelegateFlowLayout {
    /// Детерминированные высоты: один замер шаблонной ячейкой на строку, дальше — кэш.
    /// Без estimation-механики contentSize при догрузке может ТОЛЬКО расти.
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = collectionView.bounds.width
        guard width > 0,
              let id = dataSource.itemIdentifier(for: indexPath),
              let row = rowsByID[id] else {
            return CGSize(width: max(width, 1), height: 44)
        }
        if width != heightCacheWidth {
            #if DEBUG
            if heightCacheWidth > 0 { print("[LayoutDebug] invalidation reason: смена ширины \(heightCacheWidth)→\(width) — сброс кэша высот") }
            #endif
            heightCache.removeAll()
            heightCacheWidth = width
        }
        if let cached = heightCache[id] {
            return CGSize(width: width, height: cached)
        }
        configure(sizingCell, row: row, width: width)
        let height = sizingCell.measuredHeight(width: width)
        heightCache[id] = height
        return CGSize(width: width, height: height)
    }

    /// Пагинация: конец контента инвертированного списка = визуальный ВЕРХ (самые старые
    /// сообщения). Подходим к нему на ~5 строк — догружаем страницу старой истории.
    /// Позиция прокрутки сохраняется сама: старые строки добавляются В КОНЕЦ контента,
    /// рамки видимых ячеек и contentOffset не меняются.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        let total = dataSource.snapshot().numberOfItems
        guard total > 0, indexPath.item >= total - 5 else { return }
        guard model.canLoadOlder, !model.isLoadingOlder else { return }
        #if DEBUG
        print("[Pagination] старт: items=\(total) visible=\(collectionView.indexPathsForVisibleItems.map(\.item).sorted()) offset=\(collectionView.contentOffset.y) contentSize=\(collectionView.contentSize.height)")
        #endif
        Task { await model.loadOlder(peerID: peerID, settings: settings) }
    }

    /// Кнопка «вниз» — появляется, когда отошли от низа переписки дальше чем на экран
    /// (инвертированный список: низ = contentOffset.y ≈ -contentInset.top).
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let distanceFromBottom = scrollView.contentOffset.y + scrollView.contentInset.top
        let shouldShow = distanceFromBottom > scrollView.bounds.height
        guard shouldShow != scrollToBottomVisible else { return }
        scrollToBottomVisible = shouldShow
        UIView.animate(withDuration: 0.2) { self.scrollToBottomButton.alpha = shouldShow ? 1 : 0 }
    }
}

extension ChatScreenController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        model.text = textView.text
        textDidChangeUI()
        if !textView.text.isEmpty {
            Task { await model.sendTyping(peerID: peerID, settings: settings) }
        }
    }
}

/// UITextView, который сам сообщает свою высоту по контенту (до maxHeight, дальше скроллит).
final class SelfSizingTextView: UITextView {
    var maxHeight: CGFloat = 120

    override var intrinsicContentSize: CGSize {
        let fit = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        let over = fit.height > maxHeight
        if isScrollEnabled != over { isScrollEnabled = over } // за пределом — внутренний скролл
        return CGSize(width: UIView.noIntrinsicMetric, height: min(fit.height, maxHeight))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize() // ширина стала известна → пересчитать высоту
    }
}
