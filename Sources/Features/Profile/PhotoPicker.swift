import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Системный выбор фото из галереи.
struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage) -> Void
        init(onPick: @escaping (UIImage) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }

            // Быстрый путь: работает для jpeg/png/heic. Для webp и т.п. NSItemProvider
            // часто не умеет мостить в UIImage напрямую (canLoadObject = false),
            // хотя ImageIO сами байты декодирует нормально — тогда читаем файл сами.
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    if let image = object as? UIImage {
                        DispatchQueue.main.async { self.onPick(image) }
                    }
                }
                return
            }

            guard let typeID = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) else { return }

            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                guard let url, let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return }
                DispatchQueue.main.async { self.onPick(image) }
            }
        }
    }
}

/// Съёмка нового фото камерой. PHPickerViewController (см. PhotoPicker выше) не умеет
/// снимать — только выбирать существующее, поэтому камере отдельно нужен UIImagePickerController.
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, dismiss: dismiss) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage) -> Void
        let dismiss: DismissAction
        init(onPick: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onPick = onPick
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onPick(image) }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}
