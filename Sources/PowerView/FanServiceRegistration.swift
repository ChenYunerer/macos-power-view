import Foundation
import ServiceManagement
import CryptoKit
import FanService

enum FanRegistrationFailure: LocalizedError {
    case approvalRequired, unavailable
    var errorDescription: String? {
        switch self {
        case .approvalRequired: return "请在系统设置 → 通用 → 登录项中允许 Power View 的后台服务，然后重新点击“应用”。"
        case .unavailable: return "风扇服务未就绪，请将完整的正式版 Power View 安装到“应用程序”后重试。"
        }
    }
}

@MainActor
final class FanServiceRegistration {
    let team = PowerFanService.signingTeam(identifier: PowerFanService.appIdentifier)
    private let service = SMAppService.daemon(plistName: PowerFanService.plistName)
    private let fingerprintKey = "registeredFanServiceFingerprint"
    var status: SMAppService.Status { service.status }

    func prepare() async throws {
        guard team != nil else { return }
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(PowerFanService.plistName)")
        guard FileManager.default.fileExists(atPath: plist.path) else { throw FanRegistrationFailure.unavailable }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PowerFanDaemon")
        let fingerprint = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        // Updated daemon executables must be re-registered with ServiceManagement.
        if status == .enabled, UserDefaults.standard.string(forKey: fingerprintKey) != fingerprint {
            try await service.unregister()
        }
        if status == .notRegistered || status == .notFound {
            do { try service.register() }
            catch {
                if status != .requiresApproval { throw error }
            }
            UserDefaults.standard.set(fingerprint, forKey: fingerprintKey)
        }
        switch status {
        case .enabled: return
        case .requiresApproval: throw FanRegistrationFailure.approvalRequired
        default: throw FanRegistrationFailure.unavailable
        }
    }

    func disable() async throws {
        guard status != .notRegistered else { return }
        try await service.unregister()
        UserDefaults.standard.removeObject(forKey: fingerprintKey)
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
