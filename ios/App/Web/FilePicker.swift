import Foundation
import UIKit
import UniformTypeIdentifiers
import DSHBridge

/// Result of a document/camera pick, encoded for the bridge's File reply.
struct PickedFile {
    let name: String
    let mime: String
    let data: Data

    /// The flat shape the page materialises into a real `File`
    /// (dsh-mobile `client.js`, `materializeNativeFile`): `{name, mime, base64}`.
    /// The adapter still understands the older `{__file: {...}}` wrapper.
    var bridgeValue: [String: Any] {
        [
            "name": name,
            "mime": mime,
            "base64": data.base64EncodedString(),
        ]
    }
}

enum PickFailure: Error, Equatable, CustomStringConvertible, LocalizedError {
    case cancelled
    case tooLarge(Int)
    case unreadable
    /// The device cannot serve the request at all (no camera, no presenter).
    case unavailable
    /// The user refused the camera permission.
    case permissionDenied
    /// The user never finished picking; native gave up before the page did.
    case timedOut

    var description: String {
        switch self {
        case .cancelled:
            return "cancelled"
        case .tooLarge(let bytes):
            return "file is " + String(bytes) + " bytes; the limit is " + String(FilePicker.maxBytes)
        case .unreadable:
            return "the picked file could not be read"
        case .unavailable:
            return "not available on this device"
        case .permissionDenied:
            return "camera access is off; allow it in Settings > DSH > Camera"
        case .timedOut:
            return "no photo was taken before the request timed out"
        }
    }

    var errorDescription: String? { description }

    /// The page's error code for this failure (docs/03 section 5.2). Only these
    /// codes exist, so the mapping has to be total.
    var bridgeCode: BridgeFailureCode {
        switch self {
        case .cancelled:
            return .cancelled
        case .tooLarge:
            return .payloadTooLarge
        case .unavailable:
            return .unavailable
        case .permissionDenied:
            return .permissionDenied
        case .timedOut:
            return .timeout
        case .unreadable:
            return .failed
        }
    }
}

/// Picks one file and turns it into a bridge payload.
@MainActor
final class FilePicker: NSObject, UIDocumentPickerDelegate {
    /// Contract limit from docs/03 section 6.
    static let maxBytes = 8 * 1024 * 1024

    private var continuation: CheckedContinuation<PickedFile, Error>?

    func pick(from presenter: UIViewController) async throws -> PickedFile {
        let types: [UTType] = [.image, .pdf, .plainText, .data]
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        controller.delegate = self
        controller.allowsMultipleSelection = false

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            // Same lifecycle trail as the camera: without it a failed pick only
            // says "reply failed", with no sign of whether the picker appeared.
            BridgeLog.shared.append("picker presenting", detail: "from " + String(describing: type(of: presenter)))
            presenter.present(controller, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        defer { continuation = nil }
        guard let url = urls.first else {
            BridgeLog.shared.append("picker cancelled", detail: "the picker returned no URL")
            continuation?.resume(throwing: PickFailure.cancelled)
            return
        }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= FilePicker.maxBytes else {
                continuation?.resume(throwing: PickFailure.tooLarge(data.count))
                return
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            BridgeLog.shared.append(
                "picker picked",
                detail: url.lastPathComponent + " " + mime + " " + String(data.count) + "B"
            )
            continuation?.resume(returning: PickedFile(name: url.lastPathComponent, mime: mime, data: data))
        } catch {
            continuation?.resume(throwing: PickFailure.unreadable)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        BridgeLog.shared.append("picker cancelled", detail: "user dismissed the picker")
        continuation?.resume(throwing: PickFailure.cancelled)
        continuation = nil
    }
}
