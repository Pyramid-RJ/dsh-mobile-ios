import Foundation

/// One paired computer, as persisted in the Keychain.
///
/// The CA is stored next to the credentials on purpose: renewal and the web
/// view load must pin the same certificate that was verified during pairing,
/// even if the user is offline later (docs/02 section 3.1 step 2).
public struct DeviceRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    /// Serialized origin, e.g. https://192.168.1.5:3443.
    public var origin: String
    /// Gateway instance id; equals the SHA-256 of the pinned CA.
    public var instanceId: String
    public var deviceId: String
    public var deviceToken: String
    public var deviceExpiresAt: Date
    /// DER of the pinned CA.
    public var certificateAuthority: Data
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        origin: String,
        instanceId: String,
        deviceId: String,
        deviceToken: String,
        deviceExpiresAt: Date,
        certificateAuthority: Data,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.origin = origin
        self.instanceId = instanceId
        self.deviceId = deviceId
        self.deviceToken = deviceToken
        self.deviceExpiresAt = deviceExpiresAt
        self.certificateAuthority = certificateAuthority
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    public func isExpired(now: Date = Date()) -> Bool {
        deviceExpiresAt <= now
    }
}
