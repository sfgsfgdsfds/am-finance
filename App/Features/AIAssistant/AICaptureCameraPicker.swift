import SwiftUI
import UIKit

/// `UIImagePickerController` in camera mode wrapped for SwiftUI — the
/// photo-library side uses `PhotosPicker` instead, which needs no
/// permission prompt. Presented only when
/// `UIImagePickerController.isSourceTypeAvailable(.camera)` is true, so
/// the simulator never sees it.
struct AICaptureCameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController, context: Context
    ) {}

    final class Coordinator: NSObject,
        UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: AICaptureCameraPicker

        init(parent: AICaptureCameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
