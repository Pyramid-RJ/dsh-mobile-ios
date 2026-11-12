import Foundation
import DSHPairing

/// Strict JSON reader for the mobile-access responses.
///
/// The contract requires an exact key set: one extra or one missing key is an
/// invalid_response (docs/03 section 3). Codable cannot express that, so the
/// keys are compared explicitly.
struct StrictJSON {
    static let maxBytes = 32 * 1024

    let keys: Set<String>
    private let storage: [String: Any]

    init(data: Data, maxBytes: Int = StrictJSON.maxBytes) throws {
        guard data.count <= maxBytes else { throw MobileAccessFailure.invalidResponse }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw MobileAccessFailure.invalidResponse
        }
        self.storage = dictionary
        self.keys = Set(dictionary.keys)
    }

    func requireKeys(required: Set<String>, optional: Set<String> = []) throws {
        guard keys == required.union(optional) else {
            throw MobileAccessFailure.invalidResponse
        }
    }

    func string(_ key: String) throws -> String {
        guard let value = storage[key] as? String, !value.isEmpty else {
            throw MobileAccessFailure.invalidResponse
        }
        return value
    }

    func int64(_ key: String) throws -> Int64 {
        guard let number = storage[key] as? NSNumber else {
            throw MobileAccessFailure.invalidResponse
        }
        return number.int64Value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let raw = storage[key] else { return nil }
        guard let value = raw as? String, !value.isEmpty else {
            throw MobileAccessFailure.invalidResponse
        }
        return value
    }
}

/// Field formats shared by the three responses (docs/03 section 3.4).
public enum CredentialFormat {
    public static func isLowercaseHex(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    public static func isBase64URLToken(_ value: String) -> Bool {
        value.count == 43 && value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }

    public static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000.0)
    }
}

/// Response of POST /mobile-access/auth/native-pair (201).
public struct PairingCredential: Equatable, Sendable {
    public let instanceId: String
    public let deviceId: String
    public let deviceToken: String
    public let deviceExpiresAt: Date
    public let sessionToken: String
    public let csrfToken: String
    public let sessionExpiresAt: Date
    public let installationId: String?

    public init(data: Data) throws {
        let json = try StrictJSON(data: data)
        try json.requireKeys(
            required: [
                "instanceId", "deviceId", "deviceToken", "deviceExpiresAt",
                "sessionToken", "csrfToken", "sessionExpiresAt",
            ],
            optional: ["installationId"]
        )

        let instanceId = try json.string("instanceId")
        guard CredentialFormat.isLowercaseHex(instanceId, length: 64) else {
            throw MobileAccessFailure.invalidResponse
        }
        let deviceId = try json.string("deviceId")
        guard CredentialFormat.isLowercaseHex(deviceId, length: 32) else {
            throw MobileAccessFailure.invalidResponse
        }
        let deviceToken = try json.string("deviceToken")
        let sessionToken = try json.string("sessionToken")
        let csrfToken = try json.string("csrfToken")
        guard CredentialFormat.isBase64URLToken(deviceToken),
              CredentialFormat.isBase64URLToken(sessionToken),
              CredentialFormat.isBase64URLToken(csrfToken) else {
            throw MobileAccessFailure.invalidResponse
        }

        let deviceExpiresAt = CredentialFormat.date(milliseconds: try json.int64("deviceExpiresAt"))
        let sessionExpiresAt = CredentialFormat.date(milliseconds: try json.int64("sessionExpiresAt"))
        guard deviceExpiresAt >= sessionExpiresAt else {
            throw MobileAccessFailure.invalidResponse
        }

        self.instanceId = instanceId
        self.deviceId = deviceId
        self.deviceToken = deviceToken
        self.deviceExpiresAt = deviceExpiresAt
        self.sessionToken = sessionToken
        self.csrfToken = csrfToken
        self.sessionExpiresAt = sessionExpiresAt
        self.installationId = try json.optionalString("installationId")
    }
}

/// Response of POST /mobile-access/auth/native-renew (200).
public struct SessionCredential: Equatable, Sendable {
    public let instanceId: String
    public let deviceId: String
    public let sessionToken: String
    public let csrfToken: String
    public let sessionExpiresAt: Date
    public let installationId: String?

    public init(data: Data) throws {
        let json = try StrictJSON(data: data)
        try json.requireKeys(
            required: ["instanceId", "deviceId", "sessionToken", "csrfToken", "sessionExpiresAt"],
            optional: ["installationId"]
        )

        let instanceId = try json.string("instanceId")
        guard CredentialFormat.isLowercaseHex(instanceId, length: 64) else {
            throw MobileAccessFailure.invalidResponse
        }
        let deviceId = try json.string("deviceId")
        guard CredentialFormat.isLowercaseHex(deviceId, length: 32) else {
            throw MobileAccessFailure.invalidResponse
        }
        let sessionToken = try json.string("sessionToken")
        let csrfToken = try json.string("csrfToken")
        guard CredentialFormat.isBase64URLToken(sessionToken),
              CredentialFormat.isBase64URLToken(csrfToken) else {
            throw MobileAccessFailure.invalidResponse
        }

        self.instanceId = instanceId
        self.deviceId = deviceId
        self.sessionToken = sessionToken
        self.csrfToken = csrfToken
        self.sessionExpiresAt = CredentialFormat.date(milliseconds: try json.int64("sessionExpiresAt"))
        self.installationId = try json.optionalString("installationId")
    }
}

/// Response of POST /mobile-access/auth/native-probe (200).
public struct ProbeResult: Equatable, Sendable {
    public let instanceId: String
    public let deviceId: String
    public let deviceExpiresAt: Date
    public let installationId: String?

    public init(data: Data) throws {
        let json = try StrictJSON(data: data)
        try json.requireKeys(
            required: ["instanceId", "deviceId", "deviceExpiresAt"],
            optional: ["installationId"]
        )

        let instanceId = try json.string("instanceId")
        guard CredentialFormat.isLowercaseHex(instanceId, length: 64) else {
            throw MobileAccessFailure.invalidResponse
        }
        let deviceId = try json.string("deviceId")
        guard CredentialFormat.isLowercaseHex(deviceId, length: 32) else {
            throw MobileAccessFailure.invalidResponse
        }

        self.instanceId = instanceId
        self.deviceId = deviceId
        self.deviceExpiresAt = CredentialFormat.date(milliseconds: try json.int64("deviceExpiresAt"))
        self.installationId = try json.optionalString("installationId")
    }
}
