import ServiceManagement

/// Launch at login via the app itself (macOS 13+). Only works from the .app bundle.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// For `--enable-login-item`.
    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return L("켜짐")
        case .requiresApproval: return L("승인 필요 (시스템 설정 > 일반 > 로그인 항목에서 켜 주세요)")
        case .notRegistered: return L("등록 안 됨")
        case .notFound: return L("찾지 못함 (앱 번들에서 실행해 주세요)")
        @unknown default: return L("알 수 없음")
        }
    }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
