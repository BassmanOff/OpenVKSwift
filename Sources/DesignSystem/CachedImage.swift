import SwiftUI
import UIKit

/// Память-кэш уже декодированных картинок (поверх дискового URLCache).
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 400
    }

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

/// Загрузчик одной картинки: сперва память-кэш, потом сеть (URLSession уже кэширует на диск).
@MainActor
private final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    private var loadedURL: URL?

    func load(_ url: URL?) {
        guard let url else { image = nil; loadedURL = nil; return }
        if loadedURL == url, image != nil { return }
        loadedURL = url

        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        Task {
            guard let data = try? await URLSession.shared.data(from: url).0,
                  let img = UIImage(data: data) else { return }
            ImageCache.shared.insert(img, for: url)
            if loadedURL == url { image = img }
        }
    }
}

/// Кэширующий аналог AsyncImage: не перегружает одну и ту же картинку.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder
    @StateObject private var loader = ImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .onAppear { loader.load(url) }
        .onChange(of: url) { loader.load($0) }
    }
}
