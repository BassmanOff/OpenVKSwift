import SwiftUI
import UIKit
import ImageIO

/// Память-кэш уже декодированных картинок (поверх дискового URLCache).
/// Лимит — по БАЙТАМ битмапов, а не по количеству: декодированное фото весит
/// мегабайты, и «400 штук» могли раздуть память до сотен МБ.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // Достаточно просторный, чтобы лента НЕ перечитывала картинки при скролле
        // туда-сюда (маленький лимит = трэшинг = повторные декодирования = джанк).
        cache.totalCostLimit = 128 * 1024 * 1024 // ~128 МБ декодированных битмапов
    }

    /// Ключ включает размер даунсэмпла (один URL может быть нужен и миниатюрой,
    /// и крупно) и режим «raw» — чтобы тумблер оптимизации переключался на лету,
    /// не смешивая картинки двух конвейеров.
    private func key(_ url: URL, _ maxPixelSize: CGFloat, _ raw: Bool) -> NSString {
        raw ? "\(url.absoluteString)|raw" as NSString
            : "\(url.absoluteString)|\(Int(maxPixelSize))" as NSString
    }

    func image(for url: URL, maxPixelSize: CGFloat, raw: Bool = false) -> UIImage? {
        cache.object(forKey: key(url, maxPixelSize, raw))
    }

    func insert(_ image: UIImage, for url: URL, maxPixelSize: CGFloat, raw: Bool = false) {
        // Стоимость = реальный вес битмапа (RGBA, 4 байта на пиксель).
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: key(url, maxPixelSize, raw), cost: cost)
    }

    /// Стирает память-кэш декодированных картинок — отладка из настроек.
    func removeAll() { cache.removeAllObjects() }
}

/// Загрузчик одной картинки: память-кэш → сеть (диск-кэш внутри URLSession) →
/// даунсэмплинг и декодирование В ФОНЕ через ImageIO.
///
/// Даунсэмплинг — ключ к экономии: фото 4000×3000 в декодированном виде весит ~48 МБ,
/// а ужатое до размеров экрана (≤1200px) — ~5 МБ. Заодно decodирование уходит
/// с главного потока (UIImage(data:) декодировал лениво, прямо при отрисовке).
@MainActor
private final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    private var loadedURL: URL?
    private var task: Task<Void, Never>?

    deinit {
        task?.cancel() // строка ушла из List — недокачанное/недодекодированное отменяем
    }

    /// Тумблер «Оптимизация изображений» из настроек (сравнение конвейеров на лету).
    private static var optimizationEnabled: Bool {
        UserDefaults.standard.object(forKey: "image_optimization") as? Bool ?? true
    }

    func load(_ url: URL?, maxPixelSize: CGFloat) {
        guard let url else {
            task?.cancel()
            image = nil
            loadedURL = nil
            return
        }
        if loadedURL == url, image != nil { return }
        loadedURL = url
        // ВАЖНО: отмена старой задачи. Без неё быстрая прокрутка копит очередь
        // из сотен декодирований для уже невидимых строк — CPU занят, скролл виснет.
        task?.cancel()

        let optimized = Self.optimizationEnabled
        if let cached = ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize, raw: !optimized) {
            image = cached
            return
        }
        task = Task { [weak self] in
            guard let data = try? await URLSession.shared.data(from: url).0,
                  !Task.isCancelled else { return }
            let img: UIImage?
            if optimized {
                // nonisolated async → выполняется в пуле потоков (не на главном),
                // наследуя приоритет UI-задачи и отмену (в отличие от Task.detached).
                img = await Self.downsample(data: data, maxPixelSize: maxPixelSize)
            } else {
                // Старый путь: без даунсэмплинга, ленивое декодирование при отрисовке
                // (появляется раньше, но полный битмап в памяти и декод в кадре).
                img = UIImage(data: data)
            }
            guard let img, !Task.isCancelled else { return }
            ImageCache.shared.insert(img, for: url, maxPixelSize: maxPixelSize, raw: !optimized)
            if let self, self.loadedURL == url { self.image = img }
        }
    }

    nonisolated private static func downsample(data: Data, maxPixelSize: CGFloat) async -> UIImage? {
        await ImagePipeline.downsample(data: data, maxPixelSize: maxPixelSize)
    }
}

/// Общий фоновый конвейер декодирования — им пользуются CachedImage и полноэкранный
/// просмотрщик (иначе UIImage(data:) декодирует лениво ПРЯМО В КАДРЕ — рывок анимации).
enum ImagePipeline {
    /// ImageIO-даунсэмплинг: декодирует картинку сразу в нужном размере,
    /// не разворачивая полный битмап оригинала в памяти.
    nonisolated static func downsample(data: Data, maxPixelSize: CGFloat) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,      // декодировать сейчас (мы в фоне)
            kCGImageSourceCreateThumbnailWithTransform: true, // учесть EXIF-поворот
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Кэширующий аналог AsyncImage: не перегружает одну и ту же картинку.
/// `maxPixelSize` — максимальная сторона в пикселях после даунсэмплинга.
/// По умолчанию — ширина экрана в ПИКСЕЛЯХ этого устройства (750 на iPhone 8,
/// 1179 на iPhone 14 Pro): картинка в ленте не бывает крупнее ширины экрана,
/// а лишние пиксели — это лишние декодирование и память.
/// Полноэкранным просмотрщикам передаётся больше (2048).
struct CachedImage<Placeholder: View>: View {
    /// Ширина экрана в физических пикселях (вычисляется один раз).
    static var screenPixelWidth: CGFloat { UIScreen.main.nativeBounds.width }

    let url: URL?
    var contentMode: ContentMode = .fill
    var maxPixelSize: CGFloat = CachedImage<EmptyView>.screenPixelWidth
    @ViewBuilder var placeholder: () -> Placeholder
    @StateObject private var loader = ImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .onAppear { loader.load(url, maxPixelSize: maxPixelSize) }
        .onChange(of: url) { loader.load($0, maxPixelSize: maxPixelSize) }
    }
}
