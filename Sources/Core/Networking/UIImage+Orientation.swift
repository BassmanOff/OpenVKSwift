import UIKit

extension UIImage {
    /// Перерисовывает изображение в ориентации .up: сервер (OpenVK) не читает EXIF Orientation
    /// и просто сохраняет сырые пиксели, поэтому фото с камеры (portrait/landscape) без этого
    /// уходят повёрнутыми. jpegData(compressionQuality:) сам пиксели не поворачивает.
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
