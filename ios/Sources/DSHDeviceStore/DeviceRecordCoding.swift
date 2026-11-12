import Foundation

public enum DeviceStoreError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Stored bytes exist but cannot be read as a record book.
    case corrupted
    /// The Keychain refused the operation.
    case keychain(Int32)

    public var description: String {
        switch self {
        case .corrupted:
            return "stored device records are unreadable; pairing data was not cleared automatically"
        case .keychain(let status):
            return "keychain error " + String(status)
        }
    }

    public var errorDescription: String? { description }
}

/// Serializes the book with an explicit schema version.
///
/// Reading never silently turns a damaged payload into "no devices": docs/01
/// requires an error instead, because an empty list invites a silent re-pair
/// that loses the old pairing.
public enum DeviceRecordCoding {
    public static let currentVersion = 1

    struct Payload: Codable {
        var version: Int
        var records: [DeviceRecord]
    }

    public static func encode(_ book: DeviceRecordBook) throws -> Data {
        let payload = Payload(version: currentVersion, records: book.records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    public static func decode(_ data: Data) throws -> DeviceRecordBook {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            throw DeviceStoreError.corrupted
        }
        guard payload.version == currentVersion else {
            throw DeviceStoreError.corrupted
        }
        return DeviceRecordBook(records: payload.records)
    }
}
