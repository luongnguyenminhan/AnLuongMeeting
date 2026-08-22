import Foundation
import Security
import AnLuongMeetingCore

struct IOSAPIKeyStore: APIKeyStore {
    private let service = "com.anluong.meeting.gemini"
    private let account = "api-key"

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if trimmed.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        guard let data = trimmed.data(using: .utf8) else { throw APIKeyStoreError.invalidValue }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else { throw APIKeyStoreError.operationFailed(status) }
        } else if updateStatus != errSecSuccess {
            throw APIKeyStoreError.operationFailed(updateStatus)
        }
    }
}
