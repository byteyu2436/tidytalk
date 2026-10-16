import ServiceManagement

/// 开机自动启动，使用系统的登录项（SMAppService），状态以系统为准，不写进配置文件。
@MainActor
enum LoginItem {
    enum Status: Equatable {
        case enabled
        case disabled
        /// 已注册，但需要用户在"系统设置 › 通用 › 登录项"里允许。
        case requiresApproval
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled
        }
    }

    /// 返回失败原因；成功时返回 nil。
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
