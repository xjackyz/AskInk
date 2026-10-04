import Foundation
import Security

enum ProviderKey {
    private static func query(_ provider: AIProvider, service: String = "AskInk.provider") -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: provider == .openAI ? "apiKey" : "apiKey.\(provider.rawValue)"]
    }
    static func read(provider: AIProvider = .openAI) -> String {
        for service in ["AskInk.provider", "AIReader.provider"] {
            var q = query(provider, service: service)
            q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data, let value = String(data: data, encoding: .utf8) { return value }
        }
        return ""
    }
    static func save(_ value: String, provider: AIProvider = .openAI) throws {
        let bytes = Data(value.utf8)
        let update = SecItemUpdate(query(provider) as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw ReaderError.message("API Key 保存失败。") }
        var q = query(provider); q[kSecValueData as String] = bytes
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw ReaderError.message("API Key 保存失败。") }
    }
}
