import AppKit
import FanAuthorization
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
            switch parts.first {
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
    var isOpen: Bool { session != nil }

    func setSpeed(_ rpm: Double, helper: String) throws {
        if session == nil {
            var created: OpaquePointer?
            let result = PVOpenFanSession(helper, &created)
            guard result == 0, let created else { throw FanControlFailure.authorization(result) }
            session = created
        }
        try command("SET \(Int(rpm))")
    }

    func heartbeat() throws { try command("PING") }

    @discardableResult func restore() throws -> Bool {
        guard session != nil else { return false }
        try command("AUTO")
        close()
        return true
    }

    func close() {
        if let session { PVCloseFanSession(session) }
        session = nil
    }

    private func command(_ command: String) throws {
        guard let session else { throw FanControlFailure.disconnected }
        var reply = [CChar](repeating: 0, count: 256)
        let result = PVFanSessionCommand(session, command, &reply, reply.count)
        guard result == 0 else { close(); throw FanControlFailure.disconnected }
        let response = String(cString: reply)
        guard response == "OK" else {
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
    @Published var selectedRPM: Double = 3000
    @Published private(set) var busy = false
    @Published private(set) var manual = false
    @Published private(set) var canRestore = false
    @Published private(set) var message: String?
    private let session = FanSession()
    private var pulse: Task<Void, Never>?
    private var controlActivity: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var suspendRequested = false
    private var shuttingDown = false
    var onUpdate: (() -> Void)?

    init() {
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

    func prepare(_ state: FanState) {
        if state.controllable {
            selectedRPM = min(state.maximum, max(state.minimum, state.manual ? (state.target ?? selectedRPM) : selectedRPM))
        }
        editing.toggle()
    }

    func apply(_ state: FanState) {
        guard !busy, !shuttingDown, state.accepts(selectedRPM) else { return }
        let rpm = selectedRPM
        busy = true
        message = nil
        suspendRequested = false
        Task {
            do {
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PowerFanHelper").path
                try await session.setSpeed(rpm, helper: helper)
                manual = true
                if suspendRequested { await restore() }
                else { startHeartbeat(); message = "已设为 \(Int(rpm)) RPM" }
            } catch {
                stopHeartbeat()
                manual = false
                message = error.localizedDescription
                // A failed SET has already attempted rollback; close the
                // session so the next apply starts a fresh authorized helper.
                if case FanControlFailure.command(let response) = error, response.hasPrefix("ERR 6") {
                    startHeartbeat() // Keep “系统自动” available for another attempt.
                } else {
                    await session.close()
                }
            }
            canRestore = await session.isOpen
            busy = false
            onUpdate?()
        }
    }

    func automatic() {
        guard !busy, !shuttingDown else { return }
        busy = true
        Task { await restore(); busy = false; onUpdate?() }
    }

    func shutdown() async {
        shuttingDown = true
        busy = true
        suspendRequested = true
        stopHeartbeat()
        do { try await session.restore() } catch { }
        await session.close()
    }

    private func restore() async {
        stopHeartbeat()
        do {
            let restored = try await session.restore()
            manual = false
            if restored { message = "已恢复系统自动" }
        } catch { message = error.localizedDescription }
        canRestore = await session.isOpen
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
                    self.stopHeartbeat()
                    self.manual = false
                    self.canRestore = false
                    self.message = error.localizedDescription
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
