#if !MAS   // Mac App Store build (scripts/build_mas.sh) leaves this out: docs/appstore/review-notes.md
import Foundation
import Security

/// The owner's long-lived personal Claude token (from `claude setup-token`), only in the macOS Keychain: never in
/// UserDefaults, never logged, never shown again after saving. 내 Claude hands it to the CLI as CLAUDE_CODE_OAUTH_TOKEN.
enum ClaudeToken {
    /// A var only so tests and QA renders use their own item, never the owner's.
    static var service = "com.jelly.dogmonitor.claude"
    static let account = "setup-token"

    /// The pasted text as a token, or why it is not one (an API key would bill per use instead of the subscription).
    static func check(_ raw: String) -> Result<String, AICharacterClient.Failure> {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { return .failure(.init(message: L("토큰을 붙여 넣어 주세요."))) }
        if token.hasPrefix("sk-ant-api") {
            return .failure(.init(message: L("API 키는 쓰지 않아요. claude setup-token 이 만든 토큰(sk-ant-oat…)을 넣어 주세요.")))
        }
        guard token.hasPrefix("sk-ant-oat"), token.count < 400,
              token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }) else {
            return .failure(.init(message: L("claude setup-token 이 만든 토큰(sk-ant-oat…)을 그대로 붙여 넣어 주세요.")))
        }
        return .success(token)
    }

    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func save(_ token: String, service: String = ClaudeToken.service) throws {
        SecItemDelete(query(service) as CFDictionary)
        var item = query(service)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly   // stays on this Mac
        item[kSecAttrLabel as String] = "젤리 모니터 Claude 토큰"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func load(service: String = ClaudeToken.service) -> String? {
        var q = query(service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    /// Whether a token is saved, from its attributes only: no data read, so no Keychain allow dialog. Safe on main.
    static func exists(service: String = ClaudeToken.service) -> Bool {
        var q = query(service)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    static func delete(service: String = ClaudeToken.service) { SecItemDelete(query(service) as CFDictionary) }
}
#endif
