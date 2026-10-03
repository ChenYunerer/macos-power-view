import AppKit
import Combine
import PowerCore

enum ManualRefreshPhase {
    case idle, refreshing, completed, failed
}

@MainActor
final class PowerStore: ObservableObject {
    static let refreshInterval: TimeInterval = PowerHistory.sampleInterval
    @Published var snapshot: PowerSnapshot?
    @Published var temperatures = TemperatureSnapshot()
    @Published var fans: [FanState] = []
    @Published var error: String?
    @Published var samples: [PowerSample] = []
    @Published var pinned = false
    @Published var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var manualRefreshPhase = ManualRefreshPhase.idle
    var onUpdate: (() -> Void)?
    private var timer: Timer?
    private var reading = false
    private var visible = false
    private var sleeping = false
    private var generation = 0
    private var pendingRefresh = false
    private var pendingManualRefresh = false
    private var feedbackReset: Task<Void, Never>?
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
                self.pendingManualRefresh = false
                self.feedbackReset?.cancel()
                self.feedbackReset = nil
                self.manualRefreshPhase = .idle
                self.generation += 1
                self.timer?.invalidate()
                self.timer = nil
            }
        }
    }

    deinit {
        timer?.invalidate()
        feedbackReset?.cancel()
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

    func refreshManually() {
        guard !sleeping, manualRefreshPhase != .refreshing else { return }
        feedbackReset?.cancel()
        feedbackReset = nil
        manualRefreshPhase = .refreshing
        pendingManualRefresh = true
        refresh()
    }

    private func finishManualRefresh() {
        manualRefreshPhase = error == nil ? .completed : .failed
        feedbackReset = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_800_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.manualRefreshPhase = .idle
            self?.feedbackReset = nil
        }
    }

    func refresh() {
        guard !sleeping else { return }
        guard !reading else { pendingRefresh = true; return }
        reading = true
        // If an automatic read is already running, the manual request belongs
        // to the queued read, so feedback never claims completion too early.
        let manualRefresh = pendingManualRefresh
        pendingManualRefresh = false
        let startedIn = generation
        Task {
            let (result, thermal, fans) = await Task.detached(priority: .utility) {
                autoreleasepool {
                    (Result { try PowerReader.read() }, TemperatureReader.read(), FanState.readAll())
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
            self.fans = fans
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            switch result {
            case .success(let value):
                if snapshot?.connected != value.connected || error != nil { history.reset() }
                snapshot = value
                error = nil
                if let watts = value.systemConsumptionWatts {
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
            if manualRefresh { finishManualRefresh() }
        }
    }
}
