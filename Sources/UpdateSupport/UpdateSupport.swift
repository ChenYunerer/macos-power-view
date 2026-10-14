import Foundation
import Security

public struct UpdateFailure: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public struct ReleaseVersion: Comparable, Equatable {
    private let parts: [Int]
    public init?(_ value: String) {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              fields.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = fields.compactMap { Int($0) }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

public enum UpdateFiles {
    public static let appID = "local.yun.PowerView"
    public static let installerID = "local.yun.PowerView.UpdateInstaller"
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Power View/Updates", isDirectory: true)
    }
    public static var result: URL { root.appendingPathComponent("result.json") }

    public static func requirement(identifier: String, team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\" "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
            + "and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"
    }

    public static func currentTeam(identifier: String) throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw UpdateFailure("自动安装仅支持正式签名版，请先安装 GitHub Release 中的完整应用。")
        }
        var expected: SecRequirement?
        guard SecRequirementCreateWithString(requirement(identifier: identifier, team: team) as CFString, [], &expected) == errSecSuccess,
              let expected, SecCodeCheckValidity(code, [], expected) == errSecSuccess else {
            throw UpdateFailure("当前应用签名不符合更新要求。")
        }
        return team
    }

    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) throws -> String {
        // A file avoids pipe-buffer deadlocks for verbose validation failures.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        // Network-backed Gatekeeper checks must not hang installation indefinitely.
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            throw UpdateFailure("\(URL(fileURLWithPath: executable).lastPathComponent) 检查超时，请稍后重试。")
        }
        process.waitUntilExit()
        let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateFailure("\(URL(fileURLWithPath: executable).lastPathComponent) 失败：\(text.prefix(1000))")
        }
        return text
    }

    public static func version(at app: URL) throws -> String {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == appID,
              info["CFBundleExecutable"] as? String == "PowerView",
              let version = info["CFBundleShortVersionString"] as? String,
              ReleaseVersion(version) != nil else { throw UpdateFailure("更新包不是有效的 Power View 应用。") }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let parts = minimum.split(separator: ".").compactMap { Int($0) }
            guard minimum.range(of: "^[0-9]+(\\.[0-9]+){0,2}$", options: .regularExpression) != nil,
                  !parts.isEmpty, parts.count <= 3,
                  ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
                    majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0,
                    patchVersion: parts.count > 2 ? parts[2] : 0)) else {
                throw UpdateFailure("此更新要求 macOS \(minimum) 或更高版本。")
            }
        }
        return version
    }

    public static func validate(app: URL, version: String, team: String) throws {
        guard try self.version(at: app) == version else { throw UpdateFailure("更新包版本与 Release 不一致。") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R",
            "=" + requirement(identifier: appID, team: team), app.path])
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        let arch = try run("/usr/bin/lipo", ["-archs", app.appendingPathComponent("Contents/MacOS/PowerView").path])
        guard arch.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" else {
            throw UpdateFailure("更新包架构不匹配，需要 Apple Silicon 版本。")
        }
    }

    public static func validateDestination(_ app: URL) throws {
        let allowed = [URL(fileURLWithPath: "/Applications/Power View.app"),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Power View.app")]
        guard allowed.contains(app.standardizedFileURL), app.resolvingSymlinksInPath() == app.standardizedFileURL,
              FileManager.default.isWritableFile(atPath: app.path),
              FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw UpdateFailure("请将 Power View 安装到有写入权限的“应用程序”目录，再使用自动更新。")
        }
    }

    public static func extract(zip: URL, into directory: URL) throws -> URL {
        let entries = try run("/usr/bin/zipinfo", ["-1", zip.path]).split(separator: "\n")
        guard !entries.isEmpty, entries.count < 5000, entries.allSatisfy({ entry in
            (entry.hasPrefix("Power View.app/") || entry.hasPrefix("__MACOSX/Power View.app/"))
                && !entry.split(separator: "/").contains("..") && !entry.contains("\\")
        }) else { throw UpdateFailure("更新压缩包包含异常路径。") }
        let listing = try run("/usr/bin/zipinfo", ["-l", zip.path])
        var total: Int64 = 0
        for line in listing.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let mode = fields.first, mode.count == 10 else { continue }
            guard mode.first == "-" || mode.first == "d", fields.count > 3,
                  let size = Int64(fields[3]), size >= 0, size <= 200_000_000 else {
                throw UpdateFailure("更新压缩包包含不支持的链接或文件。")
            }
            total += size
        }
        guard total > 0, total <= 200_000_000 else { throw UpdateFailure("更新包解压大小超出限制。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path])
        return directory.appendingPathComponent("Power View.app")
    }
}

public struct UpdatePlan: Codable {
    public let source: URL
    public let destination: URL
    public let version: String
    public let previousVersion: String
    public let parentPID: Int32
    public init(source: URL, destination: URL, version: String, previousVersion: String, parentPID: Int32) {
        self.source = source; self.destination = destination; self.version = version
        self.previousVersion = previousVersion; self.parentPID = parentPID
    }
}

public struct UpdateResult: Codable {
    public let success: Bool
    public let message: String
    public init(success: Bool, message: String) { self.success = success; self.message = message }
}
