import Foundation

enum AppVersion {
    static let menuTitle: String = {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return "Power View · 开发版" }
        return "Power View · 版本 \(version)"
    }()
}
