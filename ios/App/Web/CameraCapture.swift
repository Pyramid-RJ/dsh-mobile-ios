import AVFoundation
import Foundation
import UIKit

/// Captures one photo and turns it into a bridge payload.
///
/// Everything that can refuse the request is decided *before* the picker is
/// presented, so the page gets a code it can act on (`unavailable`,
/// `permission_denied`, `failed`) instead of a generic failure. The camera
/// permission itself is requested once per capture here: iOS remembers the
/// answer, so the system prompt only appears while it is `.notDetermined`.
@MainActor
final class CameraCapture: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    /// A capture the user never finished must not hold the bridge slot forever
    /// (docs/03 section 5.4: the page waits 305 s, native must give up first).
    static let deadline: TimeInterval = 300

    private var continuation: CheckedContinuation<PickedFile, Error>?
    private var timeoutTask: Task<Void, Never>?

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func capture(from presenter: UIViewController) async throws -> PickedFile {
        guard CameraCapture.isAvailable else { throw PickFailure.unavailable }

        let status = Self.cameraStatus()
        if status == .denied || status == .restricted {
            throw PickFailure.permissionDenied
        }
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw PickFailure.permissionDenied }
        }

        let controller = UIImagePickerController()
        controller.sourceType = .camera
        // Only a photo is captured; there is no microphone permission to ask for.
        controller.mediaTypes = ["public.image"]
        controller.delegate = self
        // The picker is a full-screen presentation: a swipe-down dismissal would
        // never reach the delegate and would leave the page waiting.
        controller.isModalInPresentation = true

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.deadline * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(with: .failure(PickFailure.timedOut))
                controller.dismiss(animated: true)
            }
            presenter.present(controller, animated: true)
        }
    }

    /// Current camera authorisation, read off the main actor.
    static func cameraStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Stable name for the bridge log.
    static func statusName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)

        guard let image = info[.originalImage] as? UIImage,
              let data = image.jpegData(compressionQuality: 0.9) else {
            finish(with: .failure(PickFailure.unreadable))
            return
        }
        guard data.count <= FilePicker.maxBytes else {
            finish(with: .failure(PickFailure.tooLarge(data.count)))
            return
        }
        finish(with: .success(PickedFile(
            name: "photo-" + String(Int(Date().timeIntervalSince1970)) + ".jpg",
            mime: "image/jpeg",
            data: data
        )))
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        finish(with: .failure(PickFailure.cancelled))
    }

    /// Resumes the waiting request at most once, whatever ends it first.
    private func finish(with result: Result<PickedFile, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
