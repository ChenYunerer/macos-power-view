import AppKit
import SwiftUI
import PowerCore

/// Draft changes stay here: dragging never invalidates the card or its chart.
struct FanSpeedControl: View {
    let state: FanState
    @ObservedObject var control: FanControl
    @State private var draftRPM: Double = 3000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.controllable {
                HStack(spacing: 8) {
                    Text("目标转速").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    adjustment("minus", amount: -100)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(verbatim: String(Int(draftRPM)))
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .monospacedDigit().lineLimit(1).frame(width: 43, alignment: .trailing)
                        Text("RPM").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    adjustment("plus", amount: 100)
                }
                VStack(spacing: 0) {
                    FanSlider(value: $draftRPM, range: state.minimum...state.maximum,
                              enabled: !control.busy)
                        .frame(height: 34)
                        .keepsMouseInteraction()
                    HStack {
                        Text("\(Int(state.minimum))")
                        Spacer()
                        Text("\(Int(state.maximum))")
                    }
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
                }
                HStack {
                    Button("系统自动", action: control.automatic)
                        .disabled(control.busy || !control.canRestore)
                        .keepsMouseInteraction()
                    Spacer()
                    if control.busy { ProgressView().controlSize(.mini) }
                    Button("应用") {
                        control.selectedRPM = draftRPM
                        control.apply(state)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(control.busy || !state.accepts(draftRPM))
                    .help("应用目标转速；首次使用需管理员授权")
                    .accessibilityLabel("应用转速")
                    .keepsMouseInteraction()
                }
                .controlSize(.small)
                if let message = control.message {
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .keepsMouseInteraction()
                }
            } else {
                Text("此机型暂不支持手动调速。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.05), lineWidth: 0.5))
        .onAppear { draftRPM = clamped(control.selectedRPM) }
        .onChange(of: control.selectedRPM) { _, value in draftRPM = clamped(value) }
        .onChange(of: state.minimum) { _, _ in draftRPM = clamped(draftRPM) }
        .onChange(of: state.maximum) { _, _ in draftRPM = clamped(draftRPM) }
    }

    private func clamped(_ value: Double) -> Double {
        guard state.controllable else { return value }
        return min(state.maximum, max(state.minimum, value))
    }

    private func adjustment(_ symbol: String, amount: Double) -> some View {
        Button { draftRPM = clamped(draftRPM + amount) } label: {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(.primary.opacity(0.055), in: Circle())
        }
        .buttonStyle(.plain)
        .keepsMouseInteraction()
        .disabled(control.busy || (amount < 0 ? draftRPM <= state.minimum : draftRPM >= state.maximum))
        .accessibilityLabel(amount < 0 ? "降低 100 RPM" : "增加 100 RPM")
        .help(amount < 0 ? "降低 100 RPM" : "增加 100 RPM")
    }
}

/// AppKit handles continuous mouse tracking, keyboard focus and accessibility.
/// SwiftUI updates only the local numeric preview; it does not reposition the
/// native knob during tracking or snap it to coarse steps on mouse-up.
private struct FanSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let enabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.cell = FanSliderCell()
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel("目标风扇转速")
        slider.setAccessibilityHelp("方向键调整转速，点击应用后生效")
        slider.focusRingType = .default
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isEnabled = enabled
        if abs(slider.doubleValue - value) >= 1 { slider.doubleValue = value }
        slider.setAccessibilityValueDescription("\(Int(value)) RPM")
    }

    final class Coordinator: NSObject {
        var parent: FanSlider
        init(_ parent: FanSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) {
            parent.value = min(parent.range.upperBound, max(parent.range.lowerBound, slider.doubleValue.rounded()))
        }
    }
}

private final class FanSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: knobRect(flipped: flipped).midY - 3, width: rect.width, height: 6)
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let end = min(track.maxX, max(track.minX, knobRect(flipped: flipped).midX))
        let fill = NSRect(x: track.minX, y: track.minY, width: end - track.minX, height: track.height)
        NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 0.9 : 0.3).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let circle = NSRect(x: knobRect.midX - 9, y: knobRect.midY - 9, width: 18, height: 18)
        let path = NSBezierPath(ovalIn: circle)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.5).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
