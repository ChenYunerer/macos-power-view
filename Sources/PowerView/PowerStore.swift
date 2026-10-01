import AppKit
import Combine
import PowerCore

@MainActor
final class PowerStore: ObservableObject {
    static let refreshInterval: TimeInterval = 10
    @Published var snapshot: PowerSnapshot?
    @Published var temperatures = TemperatureSnapshot()
    @Published var fanRPM: Double?
    @Published var fanState = FanState()
    @Published var error: String?
    @Published var samples: [PowerSample] = []
    @Published var pinned = false
    @Published var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    var onUpdate: (() -> Void)?
    private var timer: Timer?
    private var reading = false
    private var visible = false
    private var sleeping = false
    private var generation = 0
    private var pendingRefresh = false
    private var history = PowerHistory()
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                self.generation += 1
                self.history.reset()
                self.samples = []
                self.startTimer()
                self.refresh()
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true
                self.generation += 1
                self.timer?.invalidate()
                self.timer = nil
            }
        }
    }

    deinit {
        timer?.invalidate()
        for observer in [wakeObserver, sleepObserver].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func setVisible(_ visible: Bool) {
        let opening = visible && !self.visible
        self.visible = visible
        if timer == nil && !sleeping { startTimer() }
        timer?.tolerance = visible ? 0.5 : 1
        if snapshot == nil || (opening && abs(snapshot?.date.timeIntervalSinceNow ?? 10) >= 1) { refresh() }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = visible ? 0.5 : 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard !sleeping else { return }
        guard !reading else { pendingRefresh = true; return }
        reading = true
        let startedIn = generation
        Task {
            let (result, thermal, fanState) = await Task.detached(priority: .utility) {
                autoreleasepool {
                    (Result { try PowerReader.read() }, TemperatureReader.read(), FanState.read())
                }
            }.value
            reading = false
            defer {
                if pendingRefresh {
                    pendingRefresh = false
                    refresh()
                }
            }
            guard !sleeping, generation == startedIn else { return }
            temperatures = thermal
            fanRPM = fanState.actualRPM
            self.fanState = fanState
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            switch result {
            case .success(let value):
                if snapshot?.connected != value.connected || error != nil { history.reset() }
                snapshot = value
                error = nil
                if let watts = value.primaryWatts {
                    history.append(watts: watts, at: value.date)
                } else {
                    history.reset()
                }
                samples = history.samples
            case .failure(let failure):
                error = failure.localizedDescription
                snapshot = nil
                history.reset()
                samples = []
            }
            onUpdate?()
        }
    }
}
