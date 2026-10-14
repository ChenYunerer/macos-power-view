import AppKit
import SwiftUI
import UpdateSupport

@MainActor
final class AppUpdate: ObservableObject {
    enum Phase { case idle, checking, available, downloading, ready, installing }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var release: GitHubRelease?
    @Published private(set) var progress = 0.0
    @Published private(set) var message = "从 GitHub 检查正式版本更新。"
    @Published var automaticChecks: Bool {
        didSet {
            UserDefaults.standard.set(automaticChecks, forKey: "automaticallyCheckForUpdates")
            if automaticChecks { checkIfDue() }
        }
    }
    var beforeInstall: (() async throws -> Void)?
    private let worker = ReleaseUpdate()
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var window: NSWindow?
    private var stagedApp: URL?
    private var installer: Process?
    private var installationCommitted = false
    var menuTitle: String { release.map { "发现新版本 \($0.version)…" } ?? "检查更新…" }
    var busy: Bool { [.checking, .downloading, .installing].contains(phase) }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }

    init() {
        automaticChecks = UserDefaults.standard.object(forKey: "automaticallyCheckForUpdates") as? Bool ?? true
    }

    func start() {
        var failedInstall = false
        if let data = try? Data(contentsOf: UpdateFiles.result),
           let result = try? JSONDecoder().decode(UpdateResult.self, from: data) {
            message = result.message
            try? FileManager.default.removeItem(at: UpdateFiles.result)
            if !result.success { failedInstall = true; showWindow() }
        }
        if !failedInstall { checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    func show() {
        showWindow()
        if !busy && release == nil { check() }
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Power View 软件更新"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: UpdateView(updater: self))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func checkIfDue() {
        guard automaticChecks, !busy, release == nil else { return }
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= 24 * 3600 { check() }
    }

    func check() {
        guard !busy, stagedApp == nil else { return }
        phase = .checking
        message = "正在检查 GitHub Release…"
        task = Task {
            do {
                let latest = try await worker.latest()
                try Task.checkCancellation()
                guard let current = ReleaseVersion(currentVersion), let next = ReleaseVersion(latest.version) else {
                    throw UpdateFailure("当前版本号无效，请安装正式版后再检查更新。")
                }
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                release = next > current ? latest : nil
                phase = release == nil ? .idle : .available
                message = release == nil ? "当前已是最新版本（\(currentVersion)）。" : "新版本 \(latest.version) 可用。"
            } catch {
                phase = release == nil ? .idle : .available
                message = "检查更新失败：\(error.localizedDescription)"
            }
        }
    }

    func download() {
        guard !busy, let release else { return }
        do {
            try UpdateFiles.validateDestination(Bundle.main.bundleURL)
            let team = try UpdateFiles.currentTeam(identifier: UpdateFiles.appID)
            phase = .downloading
            progress = 0
            message = "正在下载 \(release.version)…"
            task = Task {
                do {
                    stagedApp = try await worker.prepare(release, team: team) { [weak self] value in
                        Task { @MainActor in
                            guard let self, self.phase == .downloading else { return }
                            self.progress = value
                            if value == 1 { self.message = "下载完成，正在验证签名和安装包…" }
                        }
                    }
                    phase = .ready
                    message = "新版已验证，重启后完成安装。手动风扇控制将先恢复为系统自动。"
                } catch {
                    phase = .available
                    message = error is CancellationError || (error as NSError).code == NSURLErrorCancelled
                        ? "已取消下载。" : "下载更新失败：\(error.localizedDescription)"
                }
            }
        } catch { message = error.localizedDescription }
    }

    func cancelDownload() { if phase == .downloading { task?.cancel() } }

    func downloadAgain() {
        guard phase == .ready, installer?.isRunning != true else { return }
        if let stagedApp {
            try? FileManager.default.removeItem(at: stagedApp.deletingLastPathComponent().deletingLastPathComponent())
        }
        stagedApp = nil
        phase = .available
        download()
    }

    func willTerminate() {
        task?.cancel()
        if !installationCommitted, let installer, installer.isRunning { installer.terminate() }
    }

    func install() {
        guard phase == .ready, let stagedApp, let release else { return }
        phase = .installing
        message = "正在准备安装…"
        task = Task {
            do {
                try await doInstall(stagedApp: stagedApp, release: release)
            } catch {
                if let installer, installer.isRunning { installer.terminate() }
                installer = nil
                phase = .ready
                message = error.localizedDescription
            }
        }
    }
    private func doInstall(stagedApp: URL, release: GitHubRelease) async throws {
        let work = stagedApp.deletingLastPathComponent().deletingLastPathComponent()
        let plan = UpdatePlan(source: stagedApp, destination: Bundle.main.bundleURL,
                              version: release.version, previousVersion: currentVersion, parentPID: getpid())
        let planURL = work.appendingPathComponent("plan.json")
        try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
        let ready = work.appendingPathComponent("ready")
        try? FileManager.default.removeItem(at: ready)
        try? FileManager.default.removeItem(at: UpdateFiles.result)
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PowerUpdateInstaller")
        process.arguments = [planURL.path]
        try process.run()
        installer = process
        // Keep this process alive until the installer validates/stages the
        // replacement and acknowledges readiness; then use normal quit.
        let deadline = Date().addingTimeInterval(180)
        while !FileManager.default.fileExists(atPath: ready.path) {
            guard process.isRunning else {
                if let data = try? Data(contentsOf: UpdateFiles.result),
                   let result = try? JSONDecoder().decode(UpdateResult.self, from: data) {
                    throw UpdateFailure(result.message)
                }
                throw UpdateFailure("更新安装器未能启动，请重新下载更新。")
            }
            guard Date() < deadline else {
                process.terminate()
                throw UpdateFailure("准备安装超时，请稍后重试。")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await beforeInstall?()
        guard process.isRunning else { throw UpdateFailure("安装器已退出，请重新尝试安装。") }
        installationCommitted = true
        message = "正在退出并安装更新…"
        NSApp.terminate(nil)
    }

}

private struct UpdateView: View {
    @ObservedObject var updater: AppUpdate
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Power View 软件更新").font(.title2.bold())
            Text("当前版本 \(updater.currentVersion)").foregroundStyle(.secondary)
            Text(updater.message).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).help(updater.message)
            if updater.phase == .downloading {
                ProgressView(value: updater.progress)
                Text("\(Int(updater.progress * 100))%").font(.caption).monospacedDigit()
            } else if updater.busy { ProgressView().controlSize(.small) }
            if let notes = updater.release?.body, !notes.isEmpty {
                ScrollView { Text(String(notes.prefix(8000))).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(height: 130)
            }
            Toggle("每天自动检查更新", isOn: $updater.automaticChecks)
            HStack {
                Spacer()
                switch updater.phase {
                case .available:
                    Button("重新检查", action: updater.check)
                    Button("下载更新", action: updater.download).keyboardShortcut(.defaultAction)
                case .ready:
                    Button("重新下载", action: updater.downloadAgain)
                    Button("重启并安装", action: updater.install).keyboardShortcut(.defaultAction)
                case .downloading:
                    Button("取消下载", action: updater.cancelDownload)
                case .checking, .installing: EmptyView()
                case .idle: Button("检查更新", action: updater.check).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}
