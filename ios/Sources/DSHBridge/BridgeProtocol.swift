import Foundation

/// Contract constants for the page bridge (docs/03 section 5).
public enum BridgeLimits {
    public static let protocolVersion = 1
    /// Inbound message cap, matching NativeBridgePolicy.MAX_MESSAGE_BYTES.
    public static let maxInboundBytes = 1 * 1024 * 1024
    /// Reply cap; anything larger degrades to payload_too_large.
    public static let maxReplyBytes = 12 * 1024 * 1024
    public static let maxPendingRequests = 16
    public static let maxRequestIdLength = 128
    /// Clipboard cap from docs/03 section 6.
    public static let maxClipboardBytes = 256 * 1024
}

/// Error codes the page understands (docs/03 section 5.2).
public enum BridgeFailureCode: String, Equatable, Sendable {
    case badMessage = "bad_message"
    case unsupported
    case unavailable
    case cancelled
    case timeout
    case payloadTooLarge = "payload_too_large"
    case permissionDenied = "permission_denied"
    case failed
}

/// Actions the shell can advertise. The page hides features by checking this
/// list, so it must only contain what is actually implemented (docs/03 section 6.2).
public enum BridgeAction: String, CaseIterable, Hashable, Sendable {
    case authRenew = "auth.renew"
    case clipboardRead = "clipboard.read"
    case clipboardWrite = "clipboard.write"
    case share
    case filesPick = "files.pick"
    case cameraCapture = "camera.capture"
    case switchComputer = "mobile.switch-computer"
    /// Page -> shell notification: the computer dropped this device. The page
    /// fires it from the event stream (`reason: "device_revoked"`) and ignores
    /// the reply, so the shell only has to react.
    case deviceRevoked = "device.revoked"
    case displayScaleGet = "mobile.display-scale.get"
    case displayScaleSet = "mobile.display-scale.set"
}

/// Why an inbound message was rejected. Every case maps to bad_message.
public enum BridgeError: Error, Equatable, CustomStringConvertible {
    case tooLarge(Int)
    case notAnObject
    case unsupportedVersion(Int)
    case missingRequestId
    case requestIdTooLong(Int)
    case missingAction
    case inputNotAnObject

    public var code: BridgeFailureCode { .badMessage }

    public var description: String {
        switch self {
        case .tooLarge(let bytes):
            return "message is " + String(bytes) + " bytes; the limit is " + String(BridgeLimits.maxInboundBytes)
        case .notAnObject:
            return "message is not a JSON object"
        case .unsupportedVersion(let version):
            return "unsupported bridge version " + String(version)
        case .missingRequestId:
            return "missing requestId"
        case .requestIdTooLong(let length):
            return "requestId is " + String(length) + " characters; the limit is " + String(BridgeLimits.maxRequestIdLength)
        case .missingAction:
            return "missing action"
        case .inputNotAnObject:
            return "input must be an object"
        }
    }
}
