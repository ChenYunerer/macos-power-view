import SwiftUI
import Charts
import PowerCore

private final class PassThroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}

private struct FrostedBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassThroughEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 18
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct PowerCard: View {
    static let width: CGFloat = 304
    @ObservedObject var store: PowerStore
    @ObservedObject var fanControl: FanControl
    @ObservedObject var loginLaunch: LoginLaunch
    var togglePin: () -> Void
    var close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var accent: Color {
        if let s = store.snapshot, !s.connected, (s.percentage ?? 100) <= 20 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let snapshot = store.snapshot {
                summary(snapshot)
                metrics(snapshot)
                electricalDetails(snapshot)
                trend(snapshot)
                temperatureRow
                fanRow
                if fanControl.editing { fanControls }
                footer(snapshot)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: store.error == nil ? "bolt.circle" : "exclamationmark.circle")
                        .font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Text(store.error ?? "正在读取电源信息…")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if store.error != nil { Button("重新读取", action: store.refresh).keepsMouseInteraction() }
                    else { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 32)
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else {
                FrostedBackground().allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(0.09), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .overlayPreferenceValue(WindowDragExclusions.self) { anchors in
            if store.pinned {
                GeometryReader { geometry in
                    WindowDragHandle(exclusions: anchors.map { geometry[$0] })
                        .accessibilityHidden(true)
                }
            }
        }
        .alert("自动启动设置", isPresented: Binding(
            get: { loginLaunch.error != nil },
            set: { if !$0 { loginLaunch.error = nil } }
        )) {
            Button("好", role: .cancel) { loginLaunch.error = nil }
        } message: {
            Text(loginLaunch.error ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(store.snapshot.map { $0.connected ? "电脑输入功率" : "电池放电功率" } ?? "正在读取…")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            if store.lowPowerMode {
                Image(systemName: "leaf.fill").foregroundStyle(.orange)
                    .help("低电量模式已开启").accessibilityLabel("低电量模式已开启")
            }
            iconButton(store.pinned ? "pin.fill" : "pin", label: store.pinned ? "取消固定" : "固定为悬浮窗", action: togglePin)
            Menu {
                Text(AppVersion.menuTitle)
                Divider()
                Button("立即刷新", action: store.refresh)
                Button(store.pinned ? "取消固定" : "固定为悬浮窗", action: togglePin)
                Divider()
                Toggle("登录时自动启动", isOn: Binding(
                    get: { loginLaunch.enabled }, set: { loginLaunch.setEnabled($0) }
                ))
                if loginLaunch.requiresApproval {
                    Button("在系统设置中允许自动启动…", action: loginLaunch.openSettings)
                    Button("取消自动启动请求") { loginLaunch.setEnabled(false) }
                }
                Divider()
                Button("退出 Power View") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("更多选项").accessibilityLabel("更多选项")
            .keepsMouseInteraction()
            if store.pinned { iconButton("xmark", label: "收起悬浮窗", action: close) }
        }
    }

    private func summary(_ s: PowerSnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(decimal(s.primaryWatts))
                        .font(.system(size: 38, weight: .light, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                    Text("W").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                }
                Label(s.status, systemImage: s.connected ? "powerplug.fill" : "battery.75percent")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: batterySymbol(s))
                    .font(.system(size: 17, weight: .regular)).foregroundStyle(accent)
                Text(s.percentage.map { String(format: "%.0f%%", $0) } ?? "—")
                    .font(.system(size: 14, weight: .medium, design: .rounded)).monospacedDigit()
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("电池电量")
            .accessibilityValue(s.percentage.map { String(format: "%.0f%%", $0) } ?? "未知")
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: s.primaryWatts)
    }

    private func metrics(_ s: PowerSnapshot) -> some View {
        HStack(spacing: 8) {
            metric(title: s.connected ? "系统耗电" : "外部输入",
                   symbol: s.connected ? "laptopcomputer" : "powerplug",
                   value: s.connected ? s.systemWatts : 0)
            metric(title: (s.batteryWatts ?? 0) < 0 ? "电池放电" : "电池充电",
                   symbol: (s.batteryWatts ?? 0) < 0 ? "battery.75percent" : "battery.100percent.bolt",
                   value: s.batteryWatts.map(abs))
        }
    }

    private func metric(title: String, symbol: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(decimal(value)).font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
                Text("W").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func trend(_ s: PowerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(s.connected ? "输入功率趋势" : "放电功率趋势")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("最近 1 小时").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if store.samples.count > 1 {
                Chart(store.samples) { sample in
                    AreaMark(x: .value("时间", sample.date), y: .value("功率", sample.watts))
                        .foregroundStyle(LinearGradient(colors: [accent.opacity(0.18), accent.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("时间", sample.date), y: .value("功率", sample.watts))
                        .foregroundStyle(accent.opacity(0.85)).lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }
                .chartXScale(domain: s.date.addingTimeInterval(-PowerHistory.duration)...s.date)
                .chartYScale(domain: 0...max(10, (store.samples.map(\.watts).max() ?? 10) * 1.2))
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 32)
                .accessibilityLabel("最近一小时的功率变化")
            } else {
                Text("正在采集功率趋势…")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
        }
    }

    private func electricalDetails(_ s: PowerSnapshot) -> some View {
        HStack(spacing: 0) {
            specification("协商功率", value: s.adapterWatts.map { String(format: "%.0f", $0) }, unit: "W")
                .frame(width: 84)
            Divider().frame(height: 27).padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 5) {
                Text("输入电压 / 电流").font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    measurement(s.inputVolts.map { String(format: "%.2f", $0) }, unit: "V")
                    Text("/").font(.system(size: 11)).foregroundStyle(.tertiary)
                    measurement(s.inputAmps.map { String(format: "%.3f", $0) }, unit: "A")
                }
                .lineLimit(1).minimumScaleFactor(0.9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 2)
        .help("输入为电脑端读数；协商功率为充电器供电上限。未提供的数据以 — 表示。")
    }

    private func specification(_ title: String, value: String?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            measurement(value, unit: unit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func measurement(_ value: String?, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value ?? "—").font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
            if value != nil { Text(unit).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }

    private var temperatureRow: some View {
        HStack(spacing: 0) {
            temperature("CPU", value: store.temperatures.cpu)
            Divider().frame(height: 26).padding(.horizontal, 8)
            temperature("GPU", value: store.temperatures.gpu)
            Divider().frame(height: 26).padding(.horizontal, 8)
            temperature("SSD", value: store.temperatures.ssd)
            Divider().frame(height: 26).padding(.horizontal, 8)
            temperature("电池", value: store.temperatures.battery)
        }
        .padding(.horizontal, 2)
    }

    private func temperature(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            measurement(value.map { String(format: "%.0f", $0) }, unit: "°C")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) 温度")
        .accessibilityValue(value.map { String(format: "%.0f 摄氏度", $0) } ?? "设备未提供")
        .help("\(title) 当前有效测点的最高温度；— 表示设备未提供。")
    }

    private var fanRow: some View {
        HStack {
            Label("风扇", systemImage: "fan")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(store.fanState.manual ? "手动" : "自动")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            measurement(store.fanRPM.map { String(format: "%.0f", $0) }, unit: "RPM")
            Button { fanControl.prepare(store.fanState) } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless).help("风扇转速控制").accessibilityLabel("风扇转速控制")
            .keepsMouseInteraction()
        }
        .padding(.horizontal, 2)
        .help("0 RPM 表示当前停转，— 表示未提供读数。点击右侧按钮调整控制方式。")
    }

    private var fanControls: some View {
        FanSpeedControl(state: store.fanState, control: fanControl)
    }

    private func footer(_ s: PowerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.65)
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(accent).frame(width: 4, height: 4)
                    Text("每 \(Int(PowerStore.refreshInterval)) 秒刷新").font(.system(size: 10))
                }.foregroundStyle(.secondary)
                Spacer()
                Text(s.date.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel("最近更新 \(s.date.formatted(date: .omitted, time: .standard))")
            }
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
        .keepsMouseInteraction()
    }

    private func decimal(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }

    private func batterySymbol(_ snapshot: PowerSnapshot) -> String {
        if snapshot.charging { return "battery.100percent.bolt" }
        guard let percentage = snapshot.percentage else { return "battery.0percent" }
        let level = min(100, max(0, Int((percentage / 25).rounded()) * 25))
        return "battery.\(level)percent"
    }
}
