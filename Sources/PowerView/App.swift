import AppKit
import SwiftUI
import Combine
import PowerCore

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let store = PowerStore()
    private let fanControl = FanControl()
    private let loginLaunch = LoginLaunch()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var panel: FloatingPanel?
    private var sizeObserver: AnyCancellable?
    private var savePosition: DispatchWorkItem?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "电源")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.title = " — W"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: card)
        store.onUpdate = { [weak self] in self?.updateStatus() }
        fanControl.onUpdate = { [weak self] in self?.store.refresh() }
        // Only layout-affecting changes resize the panel. Coalesce telemetry
        // publications into one measurement, and never resize on slider input.
        sizeObserver = store.objectWillChange
            .merge(with: fanControl.$editing.removeDuplicates().map { _ in () },
                   fanControl.$message.removeDuplicates().map { _ in () })
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.resizePanel() }
        store.setVisible(false)
        if UserDefaults.standard.bool(forKey: "pinned") || !UserDefaults.standard.bool(forKey: "hasLaunched") {
            showPanel()
        }
        UserDefaults.standard.set(true, forKey: "hasLaunched")
    }

    private var card: PowerCard {
        PowerCard(store: store, fanControl: fanControl, loginLaunch: loginLaunch, togglePin: { [weak self] in self?.togglePin() }, close: { [weak self] in self?.hidePanel() })
    }

    private func updateStatus() {
        let value = store.snapshot?.primaryWatts.map { String(format: "%.1f W", $0) } ?? "— W"
        statusItem.button?.title = " " + value
        let symbol = store.error != nil ? "exclamationmark.circle" : (store.snapshot?.connected == true ? "bolt.fill" : "battery.75percent")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "电源")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = store.error ?? "Power View · \(store.snapshot?.status ?? "读取中") · \(value)"
        statusItem.button?.setAccessibilityLabel(statusItem.button?.toolTip)
    }

    @objc private func togglePopover() {
        loginLaunch.refresh()
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let pin = menu.addItem(withTitle: store.pinned ? "收起悬浮窗" : "固定为悬浮窗", action: #selector(contextTogglePin), keyEquivalent: "")
            pin.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 Power View", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        if store.pinned {
            panel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            store.setVisible(true)
        }
    }

    @objc private func contextTogglePin() { togglePin() }

    private func togglePin() {
        if store.pinned { hidePanel(); togglePopover() }
        else { showPanel() }
    }

    private func showPanel() {
        popover.performClose(nil)
        store.pinned = true
        UserDefaults.standard.set(true, forKey: "pinned")
        if panel == nil {
            let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: PowerCard.width, height: 330),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovable = true
            // The card overlay owns native dragging; interactive content must never
            // turn a slider or button gesture into a window move.
            panel.isMovableByWindowBackground = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            let content = NSHostingView(rootView: card)
            // The delegate owns the frame and top-edge anchoring. Hosting
            // min/max constraints otherwise resize the window behind its back.
            content.sizingOptions = [.intrinsicContentSize]
            panel.contentView = content
            if let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - PowerCard.width - 24, y: screen.visibleFrame.maxY - 354))
            }
            if let saved = UserDefaults.standard.string(forKey: "panelFrame") {
                let frame = NSRectFromString(saved)
                if frame.minX.isFinite, frame.minY.isFinite, frame.height.isFinite, frame.height > 0 {
                    panel.setFrame(NSRect(x: frame.minX, y: frame.minY, width: PowerCard.width, height: frame.height), display: false)
                }
            } else if let saved = UserDefaults.standard.string(forKey: "panelOrigin") {
                let origin = NSPointFromString(saved)
                let proposed = NSRect(origin: origin, size: panel.frame.size)
                if NSScreen.screens.contains(where: { $0.visibleFrame.contains(proposed) }) {
                    panel.setFrameOrigin(origin)
                }
            }
            self.panel = panel
        }
        resizePanel()
        keepPanelOnScreen()
        panel?.orderFrontRegardless()
        store.setVisible(true)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        store.pinned = false
        UserDefaults.standard.set(false, forKey: "pinned")
        store.setVisible(popover.isShown)
    }

    private func resizePanel() {
        guard let panel, let view = panel.contentView else { return }
        let height = view.fittingSize.height
        guard height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: PowerCard.width, height: height)
        frame = PanelPlacement.constrained(frame, to: NSScreen.screens.map(\.visibleFrame))
        panel.setFrame(frame, display: true)
    }

    private func keepPanelOnScreen() {
        guard let panel else { return }
        let frame = PanelPlacement.constrained(panel.frame, to: NSScreen.screens.map(\.visibleFrame))
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) { keepPanelOnScreen() }

    private func persistPanelFrame() {
        if let panel { UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "panelFrame") }
    }

    func windowDidMove(_ notification: Notification) {
        savePosition?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistPanelFrame() }
        savePosition = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func windowDidResize(_ notification: Notification) { windowDidMove(notification) }

    func popoverDidClose(_ notification: Notification) { store.setVisible(store.pinned) }
    func applicationDidBecomeActive(_ notification: Notification) { loginLaunch.refresh() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        savePosition?.cancel()
        persistPanelFrame()
        Task {
            await fanControl.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }
}

@main
enum PowerViewApplication {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            do {
                let snapshot = try PowerReader.read()
                print("connected=\(snapshot.connected) charging=\(snapshot.charging) battery=\(snapshot.percentage ?? -1)% input=\(snapshot.inputWatts ?? -1)W batteryPower=\(snapshot.batteryWatts ?? -1)W")
                let temperatures = TemperatureReader.read()
                func display(_ value: Double?) -> String { value.map { String(format: "%.1f°C", $0) } ?? "unavailable" }
                print("CPU=\(display(temperatures.cpu)) GPU=\(display(temperatures.gpu)) SSD=\(display(temperatures.ssd)) battery=\(display(temperatures.battery))")
                let state = FanState.read()
                print("fan=\(state.actualRPM.map { String(format: "%.0f RPM", $0) } ?? "unavailable")")
                print("fanControl=\(state.controllable) manual=\(state.manual) range=\(state.minimum)...\(state.maximum) target=\(state.target ?? -1)")
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
