import Foundation

/// The ordered list of paired computers, plus the edits the UI needs.
///
/// Pure value type so every rule below is testable without a Keychain.
public struct DeviceRecordBook: Equatable, Sendable {
    public private(set) var records: [DeviceRecord]

    public init(records: [DeviceRecord] = []) {
        self.records = records
    }

    public var isEmpty: Bool { records.isEmpty }

    public func record(origin: String, instanceId: String) -> DeviceRecord? {
        records.first { $0.origin == origin && $0.instanceId == instanceId }
    }

    /// Inserts, or replaces the record for the same gateway (origin + instance).
    /// Re-pairing the same computer keeps its position in the list.
    public mutating func upsert(_ record: DeviceRecord) {
        if let index = records.firstIndex(where: {
            $0.origin == record.origin && $0.instanceId == record.instanceId
        }) {
            var merged = record
            merged.id = records[index].id
            records[index] = merged
            return
        }
        records.insert(record, at: 0)
    }

    public mutating func remove(id: UUID) {
        records.removeAll { $0.id == id }
    }

    public mutating func rename(id: UUID, to name: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].displayName = name
    }

    public mutating func moveToFront(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let record = records.remove(at: index)
        records.insert(record, at: 0)
    }

    public mutating func markConnected(id: UUID, at date: Date = Date()) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].lastConnectedAt = date
    }
}
