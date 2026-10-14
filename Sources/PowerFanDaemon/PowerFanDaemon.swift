import Foundation
import FanService
import ThermalSensors
import OSLog
import Darwin

private final class FanPeer: NSObject, PowerFanServiceProtocol {
    let id = UUID()
    weak var connection: NSXPCConnection?
    let controller: FanDaemon
    // Accessed only on controller.queue.
    var closed = false
    init(controller: FanDaemon, connection: NSXPCConnection) {
        self.controller = controller
        self.connection = connection
    }
    func execute(_ command: String, withReply reply: @escaping (String) -> Void) {
        controller.queue.async { self.controller.execute(command, peer: self, reply: reply) }
    }
}

private final class FanDaemon: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "local.yun.PowerView.FanService.control")
    private let team: String
    private let logger = Logger(subsystem: PowerFanService.identifier, category: "control")
    private var owner: FanPeer?
    private var deadline: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var stopping = false

    init(team: String) { self.team = team }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The XPC runtime enforces the signature for messages, avoiding PID reuse races.
        connection.setCodeSigningRequirement(PowerFanService.requirement(identifier: PowerFanService.appIdentifier, team: team))
        let peer = FanPeer(controller: self, connection: connection)
        connection.exportedInterface = NSXPCInterface(with: PowerFanServiceProtocol.self)
        connection.exportedObject = peer
        connection.invalidationHandler = { [weak self, weak peer] in
            guard let self, let peer else { return }
            self.queue.async {
                peer.closed = true
                if self.owner?.id == peer.id { self.restoreDisconnectedOwner() }
            }
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.resume()
        return true
    }

    private func now() -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return UInt64(Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom))
    }

    func execute(_ command: String, peer: FanPeer, reply: (String) -> Void) {
        guard !stopping, !peer.closed else { reply("ERR 7 0 0|session closed"); return }
        if owner != nil && now() >= deadline {
            owner?.closed = true
            owner?.connection?.invalidate()
            restoreDisconnectedOwner()
        }
        guard !peer.closed else { reply("ERR 7 0 0|heartbeat expired"); return }
        guard owner == nil || owner?.id == peer.id else {
            reply("ERR 5 0 0|another Power View session owns fan control")
            return
        }
        guard command.utf8.count <= 64, !command.contains("\n"), !command.contains("\0") else {
            reply("ERR 7 \(PVFanControlMask()) \(PVFanControlIsActive() != 0 ? 1 : 0)|invalid command"); return
        }
        let fields = command.split(separator: " ", omittingEmptySubsequences: false)
        let result: Int32
        if command == "PING" {
            result = 0
        } else if command == "AUTO" {
            result = PVRestoreFanAutomatic(-1)
        } else if fields.count == 2, fields[0] == "AUTO", let fan = Int32(fields[1]), fan >= 0, fan < PV_MAX_FANS {
            result = PVRestoreFanAutomatic(fan)
        } else if fields.count == 3, fields[0] == "SET", let fan = Int32(fields[1]),
                  fan >= 0, fan < PV_MAX_FANS, let rpm = Double(fields[2]), rpm.isFinite, rpm.rounded() == rpm {
            owner = peer
            result = PVSetFanManual(fan, rpm)
        } else {
            reply("ERR 3 \(PVFanControlMask()) \(PVFanControlIsActive() != 0 ? 1 : 0)|invalid fan command"); return
        }
        let value = response(result)
        if result != 0 { logger.error("Fan operation failed: \(value, privacy: .public)") }
        if PVFanControlIsActive() != 0 {
            owner = peer
            deadline = now() + 20_000_000_000
            armWatchdog(after: 20)
        } else {
            owner = nil
            timer?.cancel()
            timer = nil
        }
        reply(value)
    }

    private func response(_ result: Int32) -> String {
        let ownership = "\(PVFanControlMask()) \(PVFanControlIsActive() != 0 ? 1 : 0)"
        guard result != 0 else { return "OK \(ownership)" }
        let detail = String(cString: PVFanControlDiagnostic())
        return "ERR \(result) \(ownership)" + (detail.isEmpty ? "" : "|\(detail)")
    }

    private func armWatchdog(after seconds: Double) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(wallDeadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let currentTime = self.now()
            if let owner = self.owner, !owner.closed, currentTime < self.deadline {
                self.armWatchdog(after: Double(self.deadline - currentTime) / 1_000_000_000)
                return
            }
            self.owner?.closed = true
            self.owner?.connection?.invalidate()
            self.restoreDisconnectedOwner()
        }
        self.timer = timer
        timer.resume()
    }

    private func restoreDisconnectedOwner() {
        let result = PVRestoreFanAutomatic(-1)
        if result == 0 {
            owner = nil
            timer?.cancel()
            timer = nil
        } else {
            logger.error("Fan restoration failed: \(self.response(result), privacy: .public)")
            // Keep ownership and retry; never hand uncertain hardware state to a new client.
            armWatchdog(after: 5)
        }
    }

    func shutdown() {
        stopping = true
        timer?.cancel()
        for _ in 0..<5 {
            if PVRestoreFanAutomatic(-1) == 0 { exit(0) }
            usleep(200_000)
        }
        logger.error("Fan service stopped before automatic restoration could be confirmed")
        exit(1)
    }
}

@main private enum PowerFanDaemonMain {
    static func main() {
        guard geteuid() == 0, getuid() == 0,
              let team = PowerFanService.signingTeam(identifier: PowerFanService.identifier) else {
            fputs("PowerFanDaemon requires root and a Developer ID signature.\n", stderr)
            exit(1)
        }
        let controller = FanDaemon(team: team)
        let listener = NSXPCListener(machServiceName: PowerFanService.identifier)
        listener.delegate = controller
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: controller.queue)
            source.setEventHandler { controller.shutdown() }
            source.resume()
            return source
        }
        listener.resume()
        withExtendedLifetime((controller, listener, signals)) { dispatchMain() }
    }
}
