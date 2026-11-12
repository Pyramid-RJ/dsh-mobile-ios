import Foundation
import Security

/// Keychain-backed persistence for the device book.
///
/// kSecAttrAccessibleWhenUnlockedThisDeviceOnly keeps the credentials out of
/// backups and off other devices, which is what docs/02 section 6 asks for.
/// Note that iOS keeps Keychain items across an app delete: load() reporting a
/// non-empty book after a reinstall is expected, not a bug.
public final class KeychainDeviceRecordStore {
    public struct Configuration {
        public var service: String
        public var account: String
        public var accessible: CFString

        public init(
            service: String = "io.example.dshmobile.ios",
            account: String = "device-records",
            accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ) {
            self.service = service
            self.account = account
            self.accessible = accessible
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func load() throws -> DeviceRecordBook {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw DeviceStoreError.corrupted }
            return try DeviceRecordCoding.decode(data)
        case errSecItemNotFound:
            return DeviceRecordBook()
        default:
            throw DeviceStoreError.keychain(status)
        }
    }

    public func save(_ book: DeviceRecordBook) throws {
        let data = try DeviceRecordCoding.encode(book)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: configuration.accessible,
        ]

        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery()
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw DeviceStoreError.keychain(addStatus)
            }
        default:
            throw DeviceStoreError.keychain(updateStatus)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceStoreError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: configuration.account,
        ]
    }
}
