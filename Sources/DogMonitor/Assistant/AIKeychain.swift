import Foundation
import Security

/// The API keys the owner pasted for 내 AI 연결 (Claude, ChatGPT, Gemini), one Keychain item per provider:
/// service com.jelly.dogmonitor.ai.<provider>. Never in UserDefaults, never logged, never shown again after saving.
enum AIKeychain {
    /// A var only so tests use their own items, never the owner's.
    static var servicePrefix = "com.jelly.dogmonitor.ai."
    static let account = "api-key"

    static func service(_ provider: BYOProvider) -> String { servicePrefix + provider.rawValue }

    private static func query(_ provider: BYOProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(provider), kSecAttrAccount as String: account]
    }

    static func save(_ key: String, for provider: BYOProvider) throws {
        SecItemDelete(query(provider) as CFDictionary)
        var item = query(provider)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly   // stays on this Mac
        item[kSecAttrLabel as String] = "캐릭모니터 \(provider.label) API 키"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    /// Reads the key's data: may show the Keychain allow dialog on an unsigned rebuild, so call it off main, when used.
    static func load(_ provider: BYOProvider) -> String? {
        var q = query(provider)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// From the attributes only (no data read, no allow dialog). Safe on main.
    static func exists(_ provider: BYOProvider) -> Bool {
        var q = query(provider)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    static func delete(_ provider: BYOProvider) { SecItemDelete(query(provider) as CFDictionary) }
}
