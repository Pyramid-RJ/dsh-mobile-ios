import Foundation
import UIKit

/// Captures one photo and turns it into a bridge payload.
@MainActor
final class CameraCapture: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private var continuation: CheckedContinuation<PickedFile, Error>?

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func capture(from presenter: UIViewController) async throws -> PickedFile {
        guard CameraCapture.isAvailable else { throw PickFailure.unreadable }

        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = self

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            presenter.present(controller, animated: true)
        }
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        defer { continuation = nil }

        guard let image = info[.originalImage] as? UIImage,
              let data = image.jpegData(compressionQuality: 0.9) else {
            continuation?.resume(throwing: PickFailure.unreadable)
            return
        }
        guard data.count <= FilePicker.maxBytes else {
            continuation?.resume(throwing: PickFailure.tooLarge(data.count))
            return
        }
        continuation?.resume(returning: PickedFile(
            name: "photo-" + String(Int(Date().timeIntervalSince1970)) + ".jpg",
            mime: "image/jpeg",
            data: data
        ))
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        continuation?.resume(throwing: PickFailure.cancelled)
        continuation = nil
    }
}
