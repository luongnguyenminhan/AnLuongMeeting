import Foundation

public protocol APIKeyStore {
    func load() -> String?
    func save(_ value: String) throws
}

public enum APIKeyStoreError: LocalizedError, Equatable, Sendable {
    case invalidValue
    case operationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidValue: return "The API key could not be encoded."
        case .operationFailed(let status): return "Could not save the Gemini API key (Keychain status \(status))."
        }
    }
}
