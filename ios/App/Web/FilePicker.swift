import Foundation
import UIKit
import UniformTypeIdentifiers

/// Result of a document/camera pick, encoded for the bridge's File reply.
struct PickedFile {
    let name: String
    let mime: String
    let data: Data

    /// The page materialises this into a real File (see BridgeScript.decodeFile).
    var bridgeValue: [String: Any] {
        [
            "__file": [
                "name": name,
                "mime": mime,
                "base64": data.base64EncodedString(),
            ],
        ]
    }
}

enum PickFailure: Error, Equatable, CustomStringConvertible, LocalizedError {
    case cancelled
    case tooLarge(Int)
    case unreadable

    var description: String {
        switch self {
        case .cancelled:
            return "cancelled"
        case .tooLarge(let bytes):
            return "file is " + String(bytes) + " bytes; the limit is " + String(FilePicker.maxBytes)
        case .unreadable:
            return "the picked file could not be read"
        }
    }

    var errorDescription: String? { description }
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
            presenter.present(controller, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        defer { continuation = nil }
        guard let url = urls.first else {
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
            continuation?.resume(returning: PickedFile(name: url.lastPathComponent, mime: mime, data: data))
        } catch {
            continuation?.resume(throwing: PickFailure.unreadable)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        continuation?.resume(throwing: PickFailure.cancelled)
        continuation = nil
    }
}
