import AVFoundation
import Foundation
import Photos
import UIKit

/// The device facts that decide whether `camera.capture` can work at all.
///
/// Every one of these used to be invisible on the phone: the page only saw
/// `reply failed`, and the reason lived in Console.app on a Mac. Shown on the
/// in-app diagnostics screen and copied with the bridge log.
@MainActor
enum DeviceDiagnostics {
    struct Line: Identifiable {
        let key: String
        let value: String
        var id: String { key }
    }

    /// Key/value pairs in display order.
    static func lines() -> [Line] {
        [
            Line(key: "system", value: UIDevice.current.systemName + " " + UIDevice.current.systemVersion),
            Line(key: "model", value: hardwareIdentifier()),
            Line(key: "build", value: appVersion()),
            Line(key: "cameraStatus", value: CameraCapture.statusName(CameraCapture.cameraStatus())),
            Line(key: "cameraAvailable", value: CameraCapture.isAvailable ? "true" : "false"),
            Line(key: "photoLibrary", value: photoLibraryStatus()),
            Line(key: "keyWindow", value: keyWindowDescription()),
            Line(key: "presented", value: presentedDescription()),
        ]
    }

    /// Plain-text version for the copy button and the bridge log.
    static func transcript() -> String {
        lines().map { $0.key + "=" + $0.value }.joined(separator: " | ")
    }

    /// "iPhone17,1" — the model that decides whether a camera exists at all.
    private static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            let bytes = buffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Which build is on the phone; a stale install explains most "fixed but still broken".
    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return version + " (" + build + ")"
    }

    private static func photoLibraryStatus() -> String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }

    /// Which window the bridge presents from (docs/09 §2: "no presenter" was
    /// one of the two ways a capture could fail within a second).
    private static func keyWindowDescription() -> String {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene else { return "no active scene" }
        let windows = scene.windows.map { window in
            (window.isKeyWindow ? "key:" : "") + String(describing: type(of: window))
        }
        return windows.joined(separator: ", ")
    }

    private static func presentedDescription() -> String {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        var chain: [String] = []
        while let current = controller?.presentedViewController {
            chain.append(String(describing: type(of: current)))
            controller = current
        }
        return chain.isEmpty ? "nothing presented" : chain.joined(separator: " > ")
    }
}
