import AppKit
import ServiceManagement

@MainActor
final class LoginLaunch: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published var error: String?

    var enabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        let current = SMAppService.mainApp.status
        if status != current { status = current }
    }

    func setEnabled(_ enabled: Bool) {
        error = nil
        refresh()
        do {
            if enabled {
                if requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    return
                }
                if !self.enabled { try SMAppService.mainApp.register() }
            } else if status == .enabled || requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = "\(enabled ? "开启" : "关闭")登录时自动启动失败：\(error.localizedDescription)"
        }
        refresh() // The switch always reflects macOS, not a saved preference.
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
