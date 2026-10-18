import Foundation

/// Masks what must never leave in a report or an echoed provider message: API keys and tokens, bearer headers,
/// the ntfy topic, email addresses and the home folder's name.
enum Redact {
    static let mask = "•••"
    static let patterns = [#"sk-[A-Za-z0-9_\-]{6,}"#, #"AIza[0-9A-Za-z_\-]{10,}"#, #"(?i)bearer\s+[A-Za-z0-9._~+/=\-]+"#,
                           #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#]

    static func secrets(_ text: String, topic: String? = nil, home: String = NSHomeDirectory()) -> String {
        var out = text
        if let topic, topic.count >= 6 { out = out.replacingOccurrences(of: topic, with: mask) }
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        for p in patterns { out = out.replacingOccurrences(of: p, with: mask, options: .regularExpression) }
        return out
    }
}

/// 문제 보내기: this app's state in a few lines for a bug mail. The owner reads all of it before it is copied or
/// mailed. Never chat, memory, mail, calendar or reminder text, and every secret is masked (Redact).
enum Diagnostics {
    static let supportMail = "cyw910306@gmail.com"   // web/support.html
    /// mailto bodies past a couple of thousand characters get cut or refused by mail apps.
    static let mailLimit = 1500

    @MainActor static func report() -> String {
        let app = AppSettings.shared, byo = BYOSettings.shared
        #if MAS
        let build = "App Store"
        #else
        let build = "direct"
        #endif
        let c = app.shownCharacter
        let id = c == .original ? app.originalID : c == .cat ? app.catID : nil   // a custom character's name stays out
        var lines = [
            "app: CharaMonitor \(AppInfo.version) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-")) \(build)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "chip: \(chip)",
            "language: \(Locale.preferredLanguages.first ?? "-")",
            "character: \(c.rawValue)\(id.map { " \($0)" } ?? "")",
            "engine: " + (byo.provider.map { "\($0.rawValue) \(byo.method.rawValue) \(byo.model($0))" } ?? "\(AssistantModel.shared.kind())"),
        ]
        if let why = byo.lastFailure { lines.append("ai failure: \(why)") }
        if let why = AssistantSettings.shared.integrationNotice { lines.append("integration: \(why)") }
        #if !MAS
        if let s = Updater.shared.status { lines.append("update: \(s)") }
        #endif
        lines += CharacterPack.skipped.map { "pack skipped: \($0)" }
        return Redact.secrets(lines.joined(separator: "\n"), topic: AssistantSettings.shared.ntfyTopic)
    }

    static func mailURL(_ report: String) -> URL? {
        Composer.mailtoURL(to: [supportMail], cc: [], subject: L("캐릭모니터 문제 보내기"),
                           body: L("어떤 문제인지 적어 주세요:") + "\n\n\n---\n" + String(report.prefix(mailLimit)))
    }

    /// "Apple M3 Pro".
    static var chip: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "-" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return "-" }
        return String(cString: buf)
    }
}
