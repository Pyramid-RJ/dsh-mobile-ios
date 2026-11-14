import Foundation

/// What can be wrong with one stored computer, decided without any network.
///
/// The app's self-check screen runs this per record so a broken pairing can be
/// spotted before blaming the network (docs/12).
public enum DeviceHealth {
    public enum Issue: Equatable, CustomStringConvertible {
        /// The device credential is past its expiry.
        case expired
        /// The stored CA cannot be parsed, so nothing can be pinned.
        case certificateUnreadable
        /// The stored CA does not hash to the instance id the record carries.
        case certificateMismatch(expected: String, actual: String)

        public var description: String {
            switch self {
            case .expired:
                return "设备凭据已过期，需要重新配对"
            case .certificateUnreadable:
                return "保存的 CA 无法解析"
            case .certificateMismatch(let expected, let actual):
                return "CA 指纹与 instance 不一致（记录 "
                    + String(expected.prefix(12)) + "… / CA " + String(actual.prefix(12)) + "…）"
            }
        }
    }

    /// - Parameters:
    ///   - record: the stored computer.
    ///   - now: clock, injectable for tests.
    ///   - caFingerprint: SHA-256 of the stored CA, or nil when it cannot be parsed.
    public static func issues(
        record: DeviceRecord,
        now: Date = Date(),
        caFingerprint: String?
    ) -> [Issue] {
        var issues: [Issue] = []
        if record.isExpired(now: now) {
            issues.append(.expired)
        }
        // No stored CA means "system trust" (a tunnel), which is not a problem.
        guard record.certificateAuthority != nil else { return issues }
        guard let caFingerprint else {
            issues.append(.certificateUnreadable)
            return issues
        }
        if caFingerprint.lowercased() != record.instanceId.lowercased() {
            issues.append(.certificateMismatch(expected: record.instanceId, actual: caFingerprint))
        }
        return issues
    }
}
