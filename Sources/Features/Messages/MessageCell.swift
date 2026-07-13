import SwiftUI
import UIKit

/// Статус доставки исходящего: часы — отправляется, галочка — отправлено,
/// две — прочитано, «!» — ошибка.
enum MessageDelivery {
    case sending, sent, read, failed
}

/// Палитра для UIKit-слоя (те же значения, что OVK.Palette).
enum OVKUI {
    static let primary       = UIColor(OVK.Palette.primary)
    static let background    = UIColor(OVK.Palette.background)
    static let card          = UIColor(OVK.Palette.card)
    static let textPrimary   = UIColor(OVK.Palette.textPrimary)
    static let textSecondary = UIColor(OVK.Palette.textSecondary)
    static let link          = UIColor(OVK.Palette.link)
}

/// Сообщение-«фото»: raw CDN-ссылка на картинку как единственный текст сообщения.
/// ЛС не поддерживают настоящие вложения через API (см. в техдокументации) — так выглядит
/// пересланная напрямую ссылка на файл; показываем её как картинку, а не как текст-ссылку.
func messageImageURL(in text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let host = url.host?.lowercased(),
          host == "cdn.openvk.org" || host == "cdn.openvk.xyz" else { return nil }
    let ext = url.pathExtension.lowercased()
    guard ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) else { return nil }
    return url
}

/// Группировка реакций для чипов: эмодзи → (сколько, есть ли моя).
/// Сортируем по эмодзи — порядок словаря случаен и «прыгал» бы между обновлениями.
func reactionGroups(_ reactions: [Int: MessageReaction]?, myID: Int) -> [(emoji: String, count: Int, mine: Bool)] {
    guard let reactions, !reactions.isEmpty else { return [] }
    var acc: [String: (count: Int, mine: Bool)] = [:]
    for (fromID, reaction) in reactions {
        var g = acc[reaction.emoji] ?? (0, false)
        g.count += 1
        if fromID == myID { g.mine = true }
        acc[reaction.emoji] = g
    }
    return acc
        .map { (emoji: $0.key, count: $0.value.count, mine: $0.value.mine) }
        .sorted { $0.emoji < $1.emoji }
}

/// UITextView, который реагирует ТОЛЬКО на тапы по ссылкам: все остальные касания проходят
/// сквозь него (прокрутка списка, long-press по пузырю, свайп-назад). Без этого текстовое
/// поле съедало бы жесты всего пузыря.
final class LinkOnlyTextView: UITextView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let attributed = attributedText, attributed.length > 0 else { return false }
        let inner = CGPoint(x: point.x - textContainerInset.left,
                            y: point.y - textContainerInset.top)
        let idx = layoutManager.characterIndex(for: inner, in: textContainer,
                                               fractionOfDistanceBetweenInsertionPoints: nil)
        guard idx < attributed.length else { return false }
        return attributed.attribute(.link, at: idx, effectiveRange: nil) != nil
    }
}

/// Галочки статуса (две галочки «прочитано» — наложение со сдвигом, как в SwiftUI-версии).
final class DeliveryMarkView: UIView {
    private let first = UIImageView()
    private let second = UIImageView()
    private var isDouble = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        for v in [first, second] {
            v.contentMode = .center
            addSubview(v)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: 14, height: 11) }

    override func layoutSubviews() {
        super.layoutSubviews()
        first.frame = isDouble ? bounds.offsetBy(dx: -2, dy: 0) : bounds
        second.frame = bounds.offsetBy(dx: 2, dy: 0)
    }

    func configure(_ status: MessageDelivery?) {
        let cfg = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        isDouble = false
        second.isHidden = true
        switch status {
        case .sending:
            first.image = UIImage(systemName: "clock", withConfiguration: cfg)
            first.tintColor = UIColor.white.withAlphaComponent(0.7)
        case .sent:
            first.image = UIImage(systemName: "checkmark", withConfiguration: cfg)
            first.tintColor = UIColor.white.withAlphaComponent(0.75)
        case .read:
            isDouble = true
            second.isHidden = false
            for v in [first, second] {
                v.image = UIImage(systemName: "checkmark", withConfiguration: cfg)
                v.tintColor = .white
            }
        case .failed:
            first.image = UIImage(systemName: "exclamationmark.circle", withConfiguration: cfg)
            first.tintColor = .systemYellow
        case nil:
            first.image = nil
        }
        setNeedsLayout()
    }
}

/// Ячейка сообщения: пузырь (текст + время + галочки) + чипы реакций под ним.
/// Самосайзящаяся (Auto Layout); выравнивание входящих/исходящих через наборы констрейнтов.
/// Коллекция инвертирована — contentView развёрнут обратно.
final class MessageCell: UICollectionViewCell {
    static let reuseID = "MessageCell"

    var onLongPress: (() -> Void)?
    var onReact: ((String) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    /// Тап по фото-баблу: URL картинки + её view (для «вылета» в полноэкранный просмотрщик).
    var onOpenImage: ((URL, UIView) -> Void)?

    private let column = UIStackView()   // пузырь + чипы, выравнивание по стороне
    private let bubble = UIView()
    private let textView = LinkOnlyTextView()
    private let photoImageView = UIImageView()
    private let bottomRow = UIStackView() // время + галочки
    private let timeLabel = UILabel()
    private let markView = DeliveryMarkView()
    private let chipsRow = UIStackView()

    /// Фиксированный размер фото-бабла — НЕ зависит от реальных размеров картинки (их не
    /// узнать заранее, ссылка ведёт просто на файл). Так высота ячейки детерминирована ДО
    /// загрузки — не нужно инвалидировать heightCache в контроллере, когда фото догрузится.
    private static let photoSize: CGFloat = 200
    private var photoLoadTask: Task<Void, Never>?
    private var currentPhotoURL: URL?

    /// Ключ текущих чипов реакций: пересобираем их ТОЛЬКО при реальном изменении —
    /// иначе каждое обновление статуса (галочки) «мигало» бы реакциями.
    private var chipsKey = ""

    private lazy var widthConstraint = contentView.widthAnchor.constraint(equalToConstant: 320)
    private lazy var incoming: [NSLayoutConstraint] = [
        column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
        column.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -50)
    ]
    private lazy var outgoing: [NSLayoutConstraint] = [
        column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
        column.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 50)
    ]
    /// Обычный текст: textView сверху, bottomRow под ним.
    private lazy var textMode: [NSLayoutConstraint] = [
        textView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
        textView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
        textView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
        bottomRow.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 2)
    ]
    /// «Фото»-сообщение: фиксированный квадрат вместо текста, bottomRow под ним.
    private lazy var photoMode: [NSLayoutConstraint] = [
        photoImageView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 4),
        photoImageView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 4),
        photoImageView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -4),
        photoImageView.widthAnchor.constraint(equalToConstant: Self.photoSize),
        photoImageView.heightAnchor.constraint(equalToConstant: Self.photoSize),
        bottomRow.topAnchor.constraint(equalTo: photoImageView.bottomAnchor, constant: 2)
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Коллекция отражена по вертикали — ячейку отражаем обратно.
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        widthConstraint.isActive = true

        column.axis = .vertical
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)

        bubble.layer.cornerRadius = 12
        bubble.layer.cornerCurve = .continuous

        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        textView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        textView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(textView)

        photoImageView.contentMode = .scaleAspectFill
        photoImageView.clipsToBounds = true
        photoImageView.layer.cornerRadius = 8
        photoImageView.backgroundColor = OVKUI.background
        photoImageView.isHidden = true
        photoImageView.isUserInteractionEnabled = true
        photoImageView.translatesAutoresizingMaskIntoConstraints = false
        photoImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(photoTapped)))
        bubble.addSubview(photoImageView)

        timeLabel.font = .preferredFont(forTextStyle: .caption2)
        bottomRow.axis = .horizontal
        bottomRow.spacing = 3
        bottomRow.alignment = .center
        bottomRow.addArrangedSubview(timeLabel)
        bottomRow.addArrangedSubview(markView)
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(bottomRow)

        chipsRow.axis = .horizontal
        chipsRow.spacing = 4

        column.addArrangedSubview(bubble)
        column.addArrangedSubview(chipsRow)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            bottomRow.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            bottomRow.leadingAnchor.constraint(greaterThanOrEqualTo: bubble.leadingAnchor, constant: 12),
            bottomRow.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8)
        ])
        NSLayoutConstraint.activate(textMode) // дефолт — текстовый режим

        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = 0.33
        bubble.addGestureRecognizer(press)
        bubble.isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelPhotoLoad()
    }

    // MARK: Конфигурация

    func configure(text: String, date: Int, isOut: Bool, status: MessageDelivery?,
                   reactions: [(emoji: String, count: Int, mine: Bool)], width: CGFloat) {
        widthConstraint.constant = width
        NSLayoutConstraint.deactivate(incoming + outgoing)
        NSLayoutConstraint.activate(isOut ? outgoing : incoming)
        column.alignment = isOut ? .trailing : .leading

        bubble.backgroundColor = isOut ? OVKUI.primary : OVKUI.card

        if let imageURL = messageImageURL(in: text) {
            NSLayoutConstraint.deactivate(textMode)
            NSLayoutConstraint.activate(photoMode)
            textView.isHidden = true
            photoImageView.isHidden = false
            loadPhoto(imageURL)
        } else {
            NSLayoutConstraint.deactivate(photoMode)
            NSLayoutConstraint.activate(textMode)
            photoImageView.isHidden = true
            textView.isHidden = false
            cancelPhotoLoad()

            // Текст с кликабельными ссылками/упоминаниями (общая линкификация с лентой).
            let attributed = NSMutableAttributedString(attributedString: NSAttributedString(linkifiedText(text)))
            let full = NSRange(location: 0, length: attributed.length)
            attributed.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .subheadline), range: full)
            attributed.addAttribute(.foregroundColor, value: isOut ? UIColor.white : OVKUI.textPrimary, range: full)
            textView.attributedText = attributed
            textView.linkTextAttributes = isOut
                ? [.foregroundColor: UIColor.white, .underlineStyle: NSUnderlineStyle.single.rawValue]
                : [.foregroundColor: OVKUI.link]
        }

        timeLabel.text = Self.timeText(date)
        timeLabel.textColor = isOut ? UIColor.white.withAlphaComponent(0.7) : OVKUI.textSecondary
        markView.configure(status)
        markView.isHidden = status == nil

        let key = reactions.map { "\($0.emoji)|\($0.count)|\($0.mine)" }.joined(separator: ",")
        if key != chipsKey {
            chipsKey = key
            chipsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for group in reactions {
                chipsRow.addArrangedSubview(makeChip(group))
            }
            chipsRow.isHidden = reactions.isEmpty
        }
    }

    /// Рамка пузыря в координатах окна (для меню действий).
    func bubbleFrameInWindow() -> CGRect? {
        guard bubble.window != nil else { return nil }
        return bubble.convert(bubble.bounds, to: nil)
    }

    /// Снимок пузыря как он отрисован — пиксель-в-пиксель копия для «поднятия» в меню.
    func bubbleSnapshot() -> UIView? {
        bubble.snapshotView(afterScreenUpdates: false)
    }

    // MARK: Расчёт высоты
    //
    // Высоты считает КОНТРОЛЛЕР через шаблонную ячейку (sizeForItemAt + кэш по id):
    // self-sizing (estimatedItemSize=automaticSize) выключен — flow layout при каждой
    // инвалидации сбрасывал высоты невидимых ячеек к оценкам, contentSize «плавал»
    // и список прыгал при пагинации. Детерминированные высоты стабильны по построению.

    /// Точная высота для заданной ширины: ТА ЖЕ Auto Layout-раскладка, что у живой ячейки
    /// (после configure) → высоты совпадают 1:1. Вызывается на шаблонной ячейке.
    func measuredHeight(width: CGFloat) -> CGFloat {
        widthConstraint.constant = width
        let size = contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return ceil(size.height)
    }

    // MARK: Детали

    @objc private func longPressed(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onLongPress?()
    }

    @objc private func photoTapped() {
        guard let currentPhotoURL else { return }
        onOpenImage?(currentPhotoURL, photoImageView) // тот же полноэкранный просмотрщик, что в ленте
    }

    /// Тот же память-кэш и даунсэмплинг-конвейер, что у CachedImage (DesignSystem) — просто
    /// UIKit-обвязка вместо SwiftUI, т.к. ячейка не-SwiftUI (self-sizing через Auto Layout).
    private func loadPhoto(_ url: URL) {
        guard currentPhotoURL != url else { return } // та же картинка — уже грузим/загружена
        currentPhotoURL = url
        photoImageView.image = nil
        photoLoadTask?.cancel()

        let maxPixel = Self.photoSize * UIScreen.main.scale
        if let cached = ImageCache.shared.image(for: url, maxPixelSize: maxPixel) {
            photoImageView.image = cached
            return
        }
        photoLoadTask = Task { @MainActor [weak self] in
            guard let data = try? await URLSession.shared.data(from: url).0, !Task.isCancelled else { return }
            guard let img = await ImagePipeline.downsample(data: data, maxPixelSize: maxPixel), !Task.isCancelled else { return }
            ImageCache.shared.insert(img, for: url, maxPixelSize: maxPixel)
            guard let self, self.currentPhotoURL == url else { return }
            self.photoImageView.image = img
        }
    }

    private func cancelPhotoLoad() {
        photoLoadTask?.cancel()
        photoLoadTask = nil
        currentPhotoURL = nil
        photoImageView.image = nil
    }

    private func makeChip(_ group: (emoji: String, count: Int, mine: Bool)) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.baseBackgroundColor = group.mine ? OVKUI.primary.withAlphaComponent(0.18) : OVKUI.card
        cfg.background.cornerRadius = 11
        cfg.background.strokeColor = group.mine ? OVKUI.primary.withAlphaComponent(0.5) : .clear
        cfg.background.strokeWidth = group.mine ? 1 : 0
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7)

        var title = AttributedString(group.emoji)
        title.font = UIFont.systemFont(ofSize: 13)
        if group.count > 1 {
            var count = AttributedString(" \(group.count)")
            count.font = UIFont.preferredFont(forTextStyle: .caption2)
            count.foregroundColor = OVKUI.textSecondary
            title += count
        }
        cfg.attributedTitle = title

        let emoji = group.emoji
        let button = UIButton(configuration: cfg)
        button.addAction(UIAction { [weak self] _ in self?.onReact?(emoji) }, for: .touchUpInside)
        return button
    }

    // DateFormatter дорог в создании — держим статически.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func timeText(_ timestamp: Int) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}

extension MessageCell: UITextViewDelegate {
    /// Ссылки открываем через приложение (handlesOVKLinks), а не системный Safari.
    func textView(_ textView: UITextView, shouldInteractWith URL: URL,
                  in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        if interaction == .invokeDefaultAction { onOpenURL?(URL) }
        return false
    }
}
