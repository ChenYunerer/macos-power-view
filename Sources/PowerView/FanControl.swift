import AppKit
import FanAuthorization
import FanService
import ServiceManagement
import PowerCore

private enum FanControlFailure: LocalizedError {
    case authorization(Int32), command(String), disconnected
    var errorDescription: String? {
        switch self {
        case .authorization(-60006): return "已取消授权，转速未更改。"
        case .authorization(let code): return "无法启动风扇控制服务（\(code)）。"
        case .disconnected: return "控制连接已断开，后台服务会尝试恢复系统自动。"
        case .command(let response):
            let parts = response.split(separator: "|", maxSplits: 1).map(String.init)
            let detail = parts.count > 1 ? "\n\(parts[1])" : ""
            let code = parts.first?.split(separator: " ").prefix(2).joined(separator: " ")
            switch code {
            case "ERR 3": return "目标转速超出硬件范围，或此机型暂不支持控制。"
            case "ERR 4": return "未能设置目标转速，已恢复自动。\(detail)"
            case "ERR 5": return "风扇已被其他程序手动控制，请先在该程序恢复自动。"
            case "ERR 6": return "未能确认恢复自动控制，请重试“系统自动”。\(detail)"
            default: return "风扇设置失败（\(response)）。"
            }
        }
    }
}

private actor FanSession {
    private var session: OpaquePointer?
    private var service: FanServiceConnection?
    private var generation = 0
    private var commandBusy = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var controlledFans: Set<Int> = []
    private(set) var needsRestore = false

    func setSpeed(_ rpm: Double, fan: Int, helper: String, team: String?) async throws {
        await acquireCommand()
        defer { releaseCommand() }
        if let team, service == nil { service = FanServiceConnection(team: team) }
        if team == nil && session == nil {
            var created: OpaquePointer?
            let result = PVOpenFanSession(helper, &created)
            guard result == 0, let created else { throw FanControlFailure.authorization(result) }
            session = created
        }
        try await command("SET \(fan) \(Int(rpm))")
    }

    func heartbeat() async throws {
        await acquireCommand()
        defer { releaseCommand() }
        try Task.checkCancellation()
        try await command("PING")
    }

    @discardableResult func restore(fan: Int? = nil) async throws -> Bool {
        await acquireCommand()
        defer { releaseCommand() }
        guard session != nil || service != nil else { return false }
        try await command(fan.map { "AUTO \($0)" } ?? "AUTO")
        if !needsRestore { close() }
        return true
    }

    func close() {
        generation += 1
        service?.close()
        service = nil
        if let session { PVCloseFanSession(session) }
        session = nil
        controlledFans = []
        needsRestore = false
    }

    // An actor can re-enter while waiting for XPC. Preserve command/reply order
    // so an old heartbeat cannot overwrite ownership returned by a newer SET.
    private func acquireCommand() async {
        if commandBusy {
            await withCheckedContinuation { commandWaiters.append($0) }
        } else { commandBusy = true }
    }

    private func releaseCommand() {
        if commandWaiters.isEmpty { commandBusy = false }
        else { commandWaiters.removeFirst().resume() }
    }

    private func command(_ command: String) async throws {
        let response: String
        let startedIn = generation
        if let service {
            do { response = try await service.execute(command) }
            catch {
                if generation == startedIn { close() }
                throw error
            }
            guard generation == startedIn else { throw FanControlFailure.disconnected }
        } else {
            guard let session else { throw FanControlFailure.disconnected }
            // The helper can include both SET and rollback diagnostics (384 bytes).
            var reply = [CChar](repeating: 0, count: 512)
            let result = PVFanSessionCommand(session, command, &reply, reply.count)
            guard result == 0 else { close(); throw FanControlFailure.disconnected }
            response = String(cString: reply)
        }
        guard let status = FanControlReply(response) else { close(); throw FanControlFailure.disconnected }
        controlledFans = status.controlledFans
        needsRestore = status.needsRestore
        guard status.code == 0 else {
            // Written by the unprivileged app, never by the root helper.
            let folder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Power View", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? "\(Date().ISO8601Format()) \(command) → \(response)\n".write(
                to: folder.appendingPathComponent("fan-control.log"), atomically: true, encoding: .utf8)
            throw FanControlFailure.command(response)
        }
    }
}

@MainActor
final class FanControl: ObservableObject {
    @Published var editing = false
    @Published var selectedRPM: [Int: Double] = [:]
    @Published private(set) var busy = false
    @Published private(set) var controlledFans: Set<Int> = []
    @Published private(set) var canRestore = false
    @Published private(set) var message: String?
    @Published private(set) var serviceStatus: SMAppService.Status = .notRegistered
    private let registration = FanServiceRegistration()
    private let session = FanSession()
    private var pulse: Task<Void, Never>?
    private var controlActivity: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var suspendRequested = false
    private var shuttingDown = false
    var onUpdate: (() -> Void)?

    init() {
        refreshAuthorization()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.suspendRequested = true
                if !self.busy {
                    self.busy = true
                    await self.restore()
                    self.busy = false
                    self.onUpdate?()
                }
            }
        }
    }

    deinit {
        pulse?.cancel()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let controlActivity { ProcessInfo.processInfo.endActivity(controlActivity) }
    }

    func prepare(_ fans: [FanState]) {
        refreshAuthorization()
        for state in fans where state.controllable {
            let draft = selectedRPM[state.id] ?? (state.manual ? state.target : nil) ?? 3000
            selectedRPM[state.id] = min(state.maximum, max(state.minimum, draft))
        }
        editing.toggle()
    }

    func apply(_ state: FanState, rpm: Double) {
        guard !busy, !shuttingDown, state.accepts(rpm) else { return }
        busy = true
        message = nil
        suspendRequested = false
        Task {
            do {
                if registration.team != nil { try await registration.prepare() }
                guard !suspendRequested, !shuttingDown else {
                    busy = false
                    refreshAuthorization()
                    return
                }
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PowerFanHelper").path
                try await session.setSpeed(rpm, fan: state.id, helper: helper, team: registration.team)
                if suspendRequested { await restore() }
                else { message = "风扇 \(state.id + 1) 已设为 \(Int(rpm)) RPM" }
            } catch {
                message = "风扇 \(state.id + 1)：\(error.localizedDescription)"
                if suspendRequested { await restore() }
            }
            await updateOwnership()
            refreshAuthorization()
            busy = false
            onUpdate?()
        }
    }

    var usesPersistentService: Bool { registration.team != nil }
    var authorizationSummary: String {
        guard usesPersistentService else { return "本地构建：首次调速仍需管理员授权。正式签名版可启用持久风扇服务。" }
        switch serviceStatus {
        case .enabled: return "风扇服务已启用，重启软件无需重复授权。"
        case .requiresApproval: return "等待系统批准风扇服务。批准后重新点击“应用”。"
        case .notRegistered: return "首次调速需在系统设置中批准风扇服务，之后可重复使用。"
        default: return "风扇服务未就绪，请重新安装完整的正式版应用。"
        }
    }

    func refreshAuthorization() { serviceStatus = registration.status }
    func openAuthorizationSettings() { registration.openSettings() }

    func disableService() {
        guard !busy, !shuttingDown else { return }
        busy = true
        Task {
            stopHeartbeat()
            do {
                try await session.restore()
                await session.close()
                try await registration.disable()
                message = "风扇服务已关闭，再次调速时可重新启用。"
            } catch { message = error.localizedDescription }
            await updateOwnership()
            refreshAuthorization()
            busy = false
            onUpdate?()
        }
    }

    func automatic(fan: Int? = nil) {
        guard !busy, !shuttingDown else { return }
        busy = true
        Task {
            await restore(fan: fan)
            if suspendRequested && fan != nil { await restore() }
            busy = false
            onUpdate?()
        }
    }

    func shutdown() async {
        shuttingDown = true
        busy = true
        suspendRequested = true
        stopHeartbeat()
        do { try await session.restore() } catch { }
        await session.close()
    }

    private func restore(fan: Int? = nil) async {
        stopHeartbeat()
        do {
            let restored = try await session.restore(fan: fan)
            if restored { message = fan.map { "风扇 \($0 + 1) 已恢复系统自动" } ?? "全部风扇已恢复系统自动" }
        } catch { message = error.localizedDescription }
        await updateOwnership()
    }

    private func updateOwnership() async {
        controlledFans = await session.controlledFans
        canRestore = await session.needsRestore
        if canRestore && !shuttingDown && !suspendRequested { startHeartbeat() }
        else if canRestore { stopHeartbeat() }
        else { stopHeartbeat(); await session.close() }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        // Keep this explicit user-controlled session responsive when hidden,
        // while allowing normal system sleep and the helper's sleep watchdog.
        controlActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "维持用户设置的风扇控制会话")
        pulse = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                do { try await self.session.heartbeat() }
                catch {
                    guard !Task.isCancelled else { return }
                    self.stopHeartbeat()
                    self.controlledFans = []
                    self.canRestore = false
                    self.message = error.localizedDescription
                    self.refreshAuthorization()
                    self.onUpdate?()
                    return
                }
            }
        }
    }

    private func stopHeartbeat() {
        pulse?.cancel()
        pulse = nil
        if let controlActivity { ProcessInfo.processInfo.endActivity(controlActivity) }
        controlActivity = nil
    }
}
