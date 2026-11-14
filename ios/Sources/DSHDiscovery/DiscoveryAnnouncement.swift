import Foundation
import DSHPairing

/// One computer announcing itself on the local network (docs/00 S-4, docs/03 §8).
///
/// The announcement is the same shape the gateway serves at
/// `/mobile-access/discovery`: exactly five keys, `protocol` 1, a 64-character
/// instance id, and an `origin` that has to agree with the host it was found on.
/// Discovery is only a convenience: a computer found here can be connected to
/// **only if it is already paired**, because the announcement carries no pairing
/// token.
public struct DiscoveryAnnouncement: Equatable, Sendable {
    public let deviceName: String
    public let origin: String
    public let port: Int
    public let instanceId: String

    /// Why an announcement was rejected; every case is "ignore it", the reason
    /// only exists for the diagnostics log.
    public enum Rejection: Error, Equatable, CustomStringConvertible {
        case notAnObject
        case keySetMismatch([String])
        case unsupportedProtocol(Int)
        case invalidInstanceId
        case invalidOrigin
        case originHostMismatch(expected: String, actual: String)

        public var description: String {
            switch self {
            case .notAnObject:
                return "announcement is not a JSON object"
            case .keySetMismatch(let keys):
                return "announcement keys are " + keys.joined(separator: ",")
            case .unsupportedProtocol(let value):
                return "announcement protocol is " + String(value) + ", expected 1"
            case .invalidInstanceId:
                return "announcement instanceId is not 64 hex characters"
            case .invalidOrigin:
                return "announcement origin is not a usable https origin"
            case .originHostMismatch(let expected, let actual):
                return "announcement origin host " + actual + " does not match " + expected
            }
        }
    }

    /// The five keys the contract allows - no more, no fewer (docs/03 §8).
    public static let keys: Set<String> = ["deviceName", "origin", "port", "protocol", "instanceId"]

    /// Parses one announcement.
    /// - Parameters:
    ///   - data: the JSON body or the joined TXT record.
    ///   - host: the host the announcement was received from, when known.
    public static func parse(_ data: Data, host: String? = nil) throws -> DiscoveryAnnouncement {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw Rejection.notAnObject
        }
        let keys = Set(dictionary.keys)
        guard keys == Self.keys else {
            // Sorted so the value is deterministic and comparable in tests.
            throw Rejection.keySetMismatch(keys.sorted())
        }
        let protocolValue = (dictionary["protocol"] as? NSNumber)?.intValue ?? -1
        guard protocolValue == 1 else {
            throw Rejection.unsupportedProtocol(protocolValue)
        }
        guard let instanceId = dictionary["instanceId"] as? String,
              instanceId.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw Rejection.invalidInstanceId
        }
        guard let originText = dictionary["origin"] as? String,
              let origin = try? PairingLink.parse(originText).origin else {
            throw Rejection.invalidOrigin
        }
        if let host, host.caseInsensitiveCompare(origin.host) != .orderedSame {
            throw Rejection.originHostMismatch(expected: host, actual: origin.host)
        }
        let port = (dictionary["port"] as? NSNumber)?.intValue ?? origin.effectivePort
        let name = (dictionary["deviceName"] as? String) ?? origin.host
        return DiscoveryAnnouncement(
            deviceName: name.isEmpty ? origin.host : name,
            origin: origin.description,
            port: port,
            instanceId: instanceId
        )
    }

    /// Parses the TXT record form: the same five keys, each value a string.
    public static func parse(txt: [String: String], host: String? = nil) throws -> DiscoveryAnnouncement {
        var object: [String: Any] = [:]
        for (key, value) in txt {
            if key == "protocol" || key == "port" {
                guard let number = Int(value) else { throw Rejection.notAnObject }
                object[key] = number
            } else {
                object[key] = value
            }
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try parse(data, host: host)
    }
}
