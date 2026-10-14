import AppKit
import Darwin
import UpdateSupport

@main
struct PowerUpdateInstaller {
    static func main() {
        var plan: UpdatePlan?
        do {
            try doInstallTask(plan: &plan)
        } catch {
            let message = "更新未完成：\(error.localizedDescription)"
            saveResult(success: false, message: message)
            if let plan, NSRunningApplication(processIdentifier: plan.parentPID) == nil {
                _ = try? UpdateFiles.run("/usr/bin/open", [plan.destination.path])
            }
            // The old app reads result.json on launch. If reopening also fails,
            // the error remains available on the next ordinary launch.
            fputs(message + "\n", stderr)
            exit(1)
        }
    }

    private static func doInstallTask(plan: inout UpdatePlan?) throws {
        guard getuid() != 0, getuid() == geteuid(), CommandLine.arguments.count == 2 else {
            throw UpdateFailure("更新安装器只能由当前用户的 Power View 启动。")
        }
        let team = try UpdateFiles.currentTeam(identifier: UpdateFiles.installerID)
        let planURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let root = UpdateFiles.root.resolvingSymlinksInPath()
        guard planURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw UpdateFailure("更新任务路径无效。")
        }
        let request = try JSONDecoder().decode(UpdatePlan.self, from: Data(contentsOf: planURL))
        guard request.parentPID == getppid(), request.parentPID > 1,
              NSRunningApplication(processIdentifier: request.parentPID)?.bundleURL?.standardizedFileURL == request.destination.standardizedFileURL,
              request.source.resolvingSymlinksInPath().path.hasPrefix(planURL.deletingLastPathComponent().path + "/"),
              let next = ReleaseVersion(request.version), let current = ReleaseVersion(request.previousVersion), next > current else {
            throw UpdateFailure("更新任务来源或版本无效。")
        }
        plan = request
        let lock = open(UpdateFiles.root.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw UpdateFailure("无法锁定更新目录。") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw UpdateFailure("另一个更新任务正在安装。") }
        try install(request, team: team)
    }

    private static func install(_ plan: UpdatePlan, team: String) throws {
        let fm = FileManager.default
        try UpdateFiles.validateDestination(plan.destination)
        try UpdateFiles.validate(app: plan.source, version: plan.version, team: team)
        let staging = plan.destination.deletingLastPathComponent()
            .appendingPathComponent(".PowerView-update-\(UUID().uuidString).app")
        try fm.copyItem(at: plan.source, to: staging)
        var keepStaging = false
        defer { if !keepStaging { try? fm.removeItem(at: staging) } }
        try UpdateFiles.validate(app: staging, version: plan.version, team: team)
        try Data().write(to: plan.source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ready"), options: .atomic)
        // Never kill the app: its normal exit restores the fan session first.
        let deadline = Date().addingTimeInterval(120)
        while kill(plan.parentPID, 0) == 0 {
            guard Date() < deadline else { throw UpdateFailure("应用尚未退出，请退出后重试更新。") }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard errno == ESRCH else { throw UpdateFailure("无法确认旧应用已退出。") }
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            !$0.isTerminated && kill($0.processIdentifier, 0) == 0
                && $0.bundleURL?.standardizedFileURL == plan.destination.standardizedFileURL
        }) else { throw UpdateFailure("另一个 Power View 实例正在运行，请退出后重试。") }
        try UpdateFiles.validateDestination(plan.destination)
        guard try UpdateFiles.version(at: plan.destination) == plan.previousVersion else {
            throw UpdateFailure("安装的版本已发生变化，请重新检查更新。")
        }
        try UpdateFiles.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R",
            "=" + UpdateFiles.requirement(identifier: UpdateFiles.appID, team: team), plan.destination.path])
        // Both bundles reside on the same volume; swap atomically so the target
        // always contains a complete app even if the installer is interrupted.
        guard renamex_np(staging.path, plan.destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateFailure("无法替换应用：\(String(cString: strerror(errno)))")
        }
        keepStaging = true // staging now holds the complete previous version.
        do {
            try UpdateFiles.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", plan.destination.path])
            saveResult(success: true, message: "已更新到 \(plan.version)。")
            try UpdateFiles.run("/usr/bin/open", [plan.destination.path])
        } catch {
            guard renamex_np(staging.path, plan.destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw UpdateFailure("新版启动失败，旧版保留在 \(staging.path)，请从该位置恢复。")
            }
            keepStaging = false
            throw error
        }
        let backup = UpdateFiles.root.appendingPathComponent("Backups/\(plan.previousVersion)-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.moveItem(at: staging, to: backup.appendingPathComponent("Power View.app"))
        } catch { /* Keep the old bundle at staging if moving the backup fails. */ }
        try? fm.removeItem(at: plan.source.deletingLastPathComponent().deletingLastPathComponent())
    }

    private static func saveResult(success: Bool, message: String) {
        if let data = try? JSONEncoder().encode(UpdateResult(success: success, message: message)) {
            try? data.write(to: UpdateFiles.result, options: .atomic)
        }
    }
}
