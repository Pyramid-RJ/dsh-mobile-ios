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
    ///
    /// While the picker is up the user is *in* the camera, so a minute of no
    /// activity is a stuck request, not a slow one; 300 s only made the failure
    /// untestable. The page's own 305 s timeout still sits above this.
    static internal(set) var deadline: TimeInterval = 60

    private var continuation: CheckedContinuation<PickedFile, Error>?
    private var timeoutTask: Task<Void, Never>?
    /// Kept so a newer request (or the page giving up) can take the picker down.
    private weak var presentedPicker: UIImagePickerController?
    /// When the picker was presented, so the log can show how long it lived.
    private var startedAt: Date?

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// Test hook for C-10: run the timeout in seconds instead of a minute.
    ///
    /// It changes only a timer, not what the camera does, so a green short run
    /// says "the deadline fires, the picker closes, the page gets `timeout`" —
    /// not "300 s is the right number". Reset with `resetDeadlineForRelease()`.
    static func useShortDeadline(_ seconds: TimeInterval) {
        deadline = seconds
    }

    static func resetDeadlineForRelease() {
        deadline = 60
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
            self.presentedPicker = controller
            // The log has to show the whole lifecycle: three captures on
            // 2026-11-14 came back `cancelled` within a second each, and
            // nothing said whether the picker had even appeared.
            self.startedAt = Date()
            BridgeLog.shared.append(
                "camera presenting",
                detail: "from " + String(describing: type(of: presenter))
            )
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
            BridgeLog.shared.append("camera shutter", detail: "no usable image in the result")
            finish(with: .failure(PickFailure.unreadable))
            return
        }
        BridgeLog.shared.append(
            "camera shutter",
            detail: String(Int(image.size.width)) + "x" + String(Int(image.size.height))
                + " jpeg " + String(data.count) + "B" + Self.lifetime(self)
        )
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
        // A tap on 取消 and "something else was presented on top" arrive here
        // identically. The log has to tell them apart: on 2026-11-14 three
        // captures all came back `cancelled` and the reason was invisible.
        BridgeLog.shared.append("camera cancelled", detail: Self.cancelReason(for: picker) + Self.lifetime(self))
        picker.dismiss(animated: true)
        finish(with: .failure(PickFailure.cancelled))
    }

    /// "after 1.2s" — how long the picker stayed up, for the log.
    static func lifetime(_ capture: CameraCapture) -> String {
        guard let startedAt = capture.startedAt else { return "" }
        return String(format: " after %.1fs", Date().timeIntervalSince(startedAt))
    }

    /// Why the picker went away, in words the log can show.
    static func cancelReason(for picker: UIViewController) -> String {
        let top = topMost()
        if picker.presentingViewController == nil {
            return "already dismissed (another presentation took over)"
        }
        if let top, top !== picker, !top.isBeingDismissed {
            return "superseded by " + String(describing: type(of: top))
        }
        return "user tapped cancel"
    }

    /// The controller currently on screen, following the presentation chain.
    static func topMost() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    /// Ends an in-flight capture because the page asked again (or gave up).
    func cancel() {
        guard continuation != nil else { return }
        BridgeLog.shared.append("camera cancelled", detail: "superseded by a newer request")
        // Not animated: the replacement picker is presented right after this
        // returns, and UIKit refuses a presentation while one is in flight.
        presentedPicker?.dismiss(animated: false)
        presentedPicker = nil
        finish(with: .failure(PickFailure.cancelled))
    }

    /// Resumes the waiting request at most once, whatever ends it first.
    private func finish(with result: Result<PickedFile, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        presentedPicker = nil
        startedAt = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
