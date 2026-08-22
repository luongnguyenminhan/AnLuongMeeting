import Foundation
import Security

final class GeminiAPIKeyStore {
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
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try remove()
            return
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainError.invalidValue
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.operationFailed(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.operationFailed(updateStatus)
        }
    }

    func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status)
        }
    }

    enum KeychainError: LocalizedError {
        case invalidValue
        case operationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidValue:
                return "The API key could not be encoded."
            case .operationFailed(let status):
                return "Could not save the Gemini API key (Keychain status \(status))."
            }
        }
    }
}
