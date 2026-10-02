import Foundation
import CoreGraphics
import PowerCore

func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    guard actual == expected else { fatalError("Expected \(expected), got \(actual)", file: file, line: line) }
}
func XCTAssertNil<T>(_ actual: T?, file: StaticString = #file, line: UInt = #line) {
    guard actual == nil else { fatalError("Expected nil, got \(String(describing: actual))", file: file, line: line) }
}

@main
struct PowerCoreChecks {
    static func main() {
        if CommandLine.arguments.contains("--benchmark") {
            for _ in 0..<5 {
                let start = ProcessInfo.processInfo.systemUptime
                _ = try? PowerReader.read()
                let power = ProcessInfo.processInfo.systemUptime
                _ = TemperatureReader.read()
                let thermal = ProcessInfo.processInfo.systemUptime
                _ = FanState.readAll()
                let end = ProcessInfo.processInfo.systemUptime
                print(String(format: "power=%.1fms temperatures=%.1fms fanState=%.1fms total=%.1fms",
                    (power-start)*1000, (thermal-power)*1000, (end-thermal)*1000, (end-start)*1000))
            }
            return
        }
        if CommandLine.arguments.contains("--soak") {
            let start = ProcessInfo.processInfo.systemUptime
            var validPower = 0, validCPU = 0, validFan = 0
            for _ in 0..<1000 {
                autoreleasepool {
                    if (try? PowerReader.read()) != nil { validPower += 1 }
                    if TemperatureReader.read().cpu != nil { validCPU += 1 }
                    if FanState.readAll().contains(where: { $0.actualRPM != nil }) { validFan += 1 }
                }
            }
            print("1000 read-only samples: power=\(validPower) CPU=\(validCPU) fan=\(validFan), elapsed=\(ProcessInfo.processInfo.systemUptime - start)s")
            return
        }
        let checks = PowerCoreChecks()
        checks.testConnectedUnitsAndCapacity()
        checks.testUnpluggedIgnoresCachedTelemetryAndDecodesSignedCurrent()
        checks.testInvalidInstantCurrentFallsBackAndMissingValuesStayUnknown()
        checks.testSystemConsumptionExcludesChargingPower()
        checks.testBatteryOnlyPresentation()
        checks.testTemperatureGroupsUseHottestValidMeasurement()
        checks.testUnavailableTemperatureDoesNotBecomeZero()
        checks.testProcessorTemperatureFallback()
        checks.testFanControlRangeValidation()
        checks.testIndependentFanOwnershipReplies()
        checks.testHistoryBoundsAndClockChanges()
        checks.testScreenChangesAndSmallDisplays()
        print("Passed 12 checks (power/battery presentation, temperatures, fan bounds/ownership/names, history, display placement).")
    }
    func testConnectedUnitsAndCapacity() {
        let snapshot = PowerSnapshot(properties: [
            "ExternalConnected": true, "IsCharging": true,
            "CurrentCapacity": 3000, "MaxCapacity": 5000,
            "PowerTelemetryData": ["SystemPowerIn": 42000, "SystemLoad": 12000,
                                   "BatteryPower": 30000, "SystemVoltageIn": 20000, "SystemCurrentIn": 2100],
            "AdapterDetails": ["Watts": 65],
        ])
        XCTAssertEqual(snapshot.percentage, 60)
        XCTAssertEqual(snapshot.inputWatts, 42)
        XCTAssertEqual(snapshot.batteryWatts, 30)
        XCTAssertEqual(snapshot.inputVolts, 20)
        XCTAssertEqual(snapshot.inputAmps, 2.1)
    }

    func testUnpluggedIgnoresCachedTelemetryAndDecodesSignedCurrent() {
        let snapshot = PowerSnapshot(properties: [
            "ExternalConnected": false, "Voltage": 12000,
            "InstantAmperage": NSNumber(value: UInt64.max - 999),
            "PowerTelemetryData": ["SystemPowerIn": 42000, "BatteryPower": 30000],
            "AdapterDetails": ["Watts": 65],
        ])
        XCTAssertEqual(snapshot.inputWatts, 0)
        XCTAssertEqual(snapshot.batteryWatts, -12)
        XCTAssertEqual(snapshot.primaryWatts, 12)
        XCTAssertNil(snapshot.adapterWatts)
        XCTAssertNil(snapshot.systemWatts)
    }

    func testInvalidInstantCurrentFallsBackAndMissingValuesStayUnknown() {
        let snapshot = PowerSnapshot(properties: [
            "InstantAmperage": true, "Amperage": -500, "Voltage": 12000,
            "CurrentCapacity": 50, "MaxCapacity": 0,
        ])
        XCTAssertEqual(snapshot.batteryWatts, -6)
        XCTAssertNil(snapshot.percentage)
        let missing = PowerSnapshot(properties: ["ExternalConnected": true,
            "PowerTelemetryData": ["SystemPowerIn": Double.nan, "BatteryPower": true]])
        XCTAssertNil(missing.inputWatts)
        XCTAssertNil(missing.batteryWatts)
    }

    func testSystemConsumptionExcludesChargingPower() {
        let charging = PowerSnapshot(properties: [
            "ExternalConnected": true, "IsCharging": true,
            "PowerTelemetryData": ["SystemPowerIn": 42000, "SystemLoad": 12000, "BatteryPower": 30000],
        ])
        XCTAssertEqual(charging.primaryWatts, 42)
        XCTAssertEqual(charging.systemConsumptionWatts, 12)
        let battery = PowerSnapshot(properties: [
            "ExternalConnected": false, "Voltage": 12000, "InstantAmperage": -1000,
            "PowerTelemetryData": ["SystemPowerIn": 42000, "SystemLoad": 30000],
        ])
        XCTAssertEqual(battery.systemConsumptionWatts, 12) // Ignore cached AC telemetry.
        let unknown = PowerSnapshot(properties: [
            "ExternalConnected": true, "PowerTelemetryData": ["SystemPowerIn": 42000],
        ])
        XCTAssertNil(unknown.systemConsumptionWatts) // Input power includes charging, so cannot substitute.
        XCTAssertNil(PowerSnapshot(properties: [:]).systemConsumptionWatts)
        for invalid in [Double.nan, .infinity, -1000] {
            XCTAssertNil(PowerSnapshot(properties: ["ExternalConnected": true,
                "PowerTelemetryData": ["SystemLoad": invalid]]).systemConsumptionWatts)
        }
        XCTAssertEqual(PowerSnapshot(properties: ["ExternalConnected": true,
            "PowerTelemetryData": ["SystemLoad": 0]]).systemConsumptionWatts, 0)
    }

    func testBatteryOnlyPresentation() {
        let battery = PowerSnapshot(properties: ["ExternalConnected": false,
            "InstantAmperage": -1000, "Voltage": 12000,
            "AdapterDetails": ["Watts": 90],
            "PowerTelemetryData": ["SystemVoltageIn": 20000, "SystemCurrentIn": 2000, "BatteryPower": 30000]])
        XCTAssertEqual(battery.showsInputDetails, false)
        XCTAssertEqual(battery.batteryIsDischarging, true)
        XCTAssertEqual(battery.batteryWatts, -12)
        let unavailable = PowerSnapshot(properties: ["ExternalConnected": false])
        XCTAssertEqual(unavailable.showsInputDetails, false)
        XCTAssertEqual(unavailable.batteryIsDischarging, true)
        XCTAssertNil(unavailable.batteryWatts)
        let charging = PowerSnapshot(properties: ["ExternalConnected": true, "IsCharging": true,
            "PowerTelemetryData": ["BatteryPower": 30000]])
        XCTAssertEqual(charging.showsInputDetails, true)
        XCTAssertEqual(charging.batteryIsDischarging, false)
        let drainingOnAC = PowerSnapshot(properties: ["ExternalConnected": true,
            "PowerTelemetryData": ["BatteryPower": -5000]])
        XCTAssertEqual(drainingOnAC.showsInputDetails, true)
        XCTAssertEqual(drainingOnAC.batteryIsDischarging, true)
    }

    func testTemperatureGroupsUseHottestValidMeasurement() {
        let snapshot = TemperatureSnapshot(readings: [
            .init(name: "eACC MTR Temp Sensor0", celsius: 42),
            .init(name: "pACC MTR Temp Sensor2", celsius: 54),
            .init(name: "pACC MTR Temp Sensor3", celsius: -21),
            .init(name: "GPU MTR Temp Sensor1", celsius: 30),
            .init(name: "GPU MTR Temp Sensor4", celsius: 47),
            .init(name: "NAND CH0 temp", celsius: 41),
            .init(name: "NAND CH1 temp", celsius: 44),
            .init(name: "PMU tdie1", celsius: 70),
            .init(name: "gas gauge battery", celsius: 30.9),
            .init(name: "gas gauge battery", celsius: 32),
        ])
        XCTAssertEqual(snapshot.cpu, 54)
        XCTAssertEqual(snapshot.gpu, 47)
        XCTAssertEqual(snapshot.ssd, 44)
        XCTAssertEqual(snapshot.battery, 32)
    }

    func testUnavailableTemperatureDoesNotBecomeZero() {
        let snapshot = TemperatureSnapshot(readings: [
            .init(name: "pACC MTR Temp Sensor2", celsius: .nan),
            .init(name: "eACC MTR Temp Sensor0", celsius: 0),
            .init(name: "GPU MTR Temp Sensor1", celsius: .infinity),
            .init(name: "GPU MTR Temp Sensor4", celsius: 200),
            .init(name: "NAND CH0 temp", celsius: -21),
            .init(name: "gas gauge battery", celsius: .nan),
            .init(name: "gas gauge battery", celsius: 0),
        ])
        XCTAssertNil(snapshot.cpu)
        XCTAssertNil(snapshot.gpu)
        XCTAssertNil(snapshot.ssd)
        XCTAssertNil(snapshot.battery)
        XCTAssertNil(TemperatureSnapshot().battery)
        XCTAssertNil(TemperatureSnapshot().cpu)
    }

    func testProcessorTemperatureFallback() {
        let hid = [TemperatureReading(name: "NAND CH0 temp", celsius: 39),
                   TemperatureReading(name: "gas gauge battery", celsius: 28)]
        let m4Pro = TemperatureSnapshot(readings: hid, fallbackCPU: 57.9, fallbackGPU: 53.1)
        XCTAssertEqual(m4Pro.cpu, 57.9)
        XCTAssertEqual(m4Pro.gpu, 53.1)
        XCTAssertEqual(m4Pro.ssd, 39)
        XCTAssertEqual(m4Pro.battery, 28)

        let cpuOnly = TemperatureSnapshot(readings: hid + [.init(name: "pACC MTR Temp Sensor0", celsius: 42)],
                                          fallbackCPU: 70, fallbackGPU: 53)
        XCTAssertEqual(cpuOnly.cpu, 42)
        XCTAssertEqual(cpuOnly.gpu, 53)
        let gpuOnly = TemperatureSnapshot(readings: [.init(name: "GPU MTR Temp Sensor0", celsius: 45)],
                                          fallbackCPU: 57, fallbackGPU: 80)
        XCTAssertEqual(gpuOnly.cpu, 57)
        XCTAssertEqual(gpuOnly.gpu, 45)

        for invalid in [Double.nan, .infinity, -.infinity, 0, -1, 125.1] {
            let missing = TemperatureSnapshot(readings: hid, fallbackCPU: invalid, fallbackGPU: invalid)
            XCTAssertNil(missing.cpu)
            XCTAssertNil(missing.gpu)
            XCTAssertEqual(missing.ssd, 39)
            XCTAssertEqual(missing.battery, 28)
        }
        XCTAssertEqual(TemperatureSnapshot(fallbackCPU: 125, fallbackGPU: 0.5).cpu, 125)
        XCTAssertEqual(TemperatureSnapshot(fallbackCPU: 125, fallbackGPU: 0.5).gpu, 0.5)
        // A failed next sample must not retain the previous SMC readings.
        XCTAssertNil(TemperatureSnapshot(readings: hid).cpu)
        XCTAssertNil(TemperatureSnapshot(readings: hid).gpu)
    }

    func testFanControlRangeValidation() {
        let state = FanState(minimum: 1199, maximum: 7199, controllable: true)
        XCTAssertEqual(state.accepts(1199), true)
        XCTAssertEqual(state.accepts(7199), true)
        for value in [0, 1198, 7200, 3000.5, Double.nan, Double.infinity] {
            XCTAssertEqual(state.accepts(value), false)
        }
        XCTAssertEqual(FanState().accepts(3000), false)
        XCTAssertEqual(FanState(minimum: .nan, maximum: 7199, controllable: true).controllable, false)
        XCTAssertEqual(FanState(minimum: 7199, maximum: 1199, controllable: true).controllable, false)
        XCTAssertNil(FanState(actualRPM: .infinity).actualRPM)
        XCTAssertNil(FanState(actualRPM: -1).actualRPM)
        XCTAssertEqual(FanState(actualRPM: 0).actualRPM, 0)
    }

    func testIndependentFanOwnershipReplies() {
        XCTAssertEqual(FanControlReply("OK 3 1")?.controlledFans, Set([0, 1]))
        XCTAssertEqual(FanControlReply("OK 2 1")?.controlledFans, Set([1]))
        XCTAssertEqual(FanControlReply("OK 0 0")?.needsRestore, false)
        let partial = FanControlReply("ERR 6 2 1|F1Md readback=1 expected=0")
        XCTAssertEqual(partial?.code, 6)
        XCTAssertEqual(partial?.controlledFans, Set([1]))
        XCTAssertEqual(partial?.needsRestore, true)
        XCTAssertEqual(FanControlReply("ERR 6 0 1|Ftst readback=1 expected=0")?.needsRestore, true)
        XCTAssertEqual(FanControlReply("OK 65535 1")?.controlledFans.count, 16)
        for invalid in ["", "OK", "|", "ERR", "OK 1 0", "OK 65536 1", "OK -1 1", "OK 0 2",
                        "ERR x 0 0", "ERR 0 0 0", "ERR 8 0 0", "OK 0 0 extra", "READY 0 0"] {
            XCTAssertNil(FanControlReply(invalid))
        }
        let first = FanState(id: 0, minimum: 1199, maximum: 7199, controllable: true)
        let second = FanState(id: 1, minimum: 2317, maximum: 7826, controllable: true)
        XCTAssertEqual(first.accepts(2000), true)
        XCTAssertEqual(second.accepts(2000), false)
        XCTAssertEqual(second.id, 1)
        XCTAssertEqual(FanState(id: 0, name: " Left side ").displayName, "Left side (1)")
        XCTAssertEqual(FanState(id: 1, name: "  ").displayName, "风扇 2")
        XCTAssertNil(FanState(id: 0, name: "").name)
    }

    func testHistoryBoundsAndClockChanges() {
        var history = PowerHistory()
        let start = Date(timeIntervalSince1970: 1000)
        for i in 0..<1000 { history.append(watts: 10, at: start.addingTimeInterval(Double(i) / 10)) }
        XCTAssertEqual(history.samples.count, 10)
        let lastID = history.samples.last!.id
        history.append(watts: 12, at: start.addingTimeInterval(99.9))
        XCTAssertEqual(history.samples.count, 10)
        XCTAssertEqual(history.samples.last!.id, lastID)
        XCTAssertEqual(history.samples.last!.watts, 12)
        history.append(watts: .nan, at: start.addingTimeInterval(100))
        XCTAssertEqual(history.samples.count, 10)
        history.reset()
        for i in 0...720 { history.append(watts: 10, at: start.addingTimeInterval(Double(i) * 10)) }
        XCTAssertEqual(history.samples.count, 361)
        XCTAssertEqual(history.samples.first!.date, start.addingTimeInterval(3600))
        XCTAssertEqual(history.samples.last!.date, start.addingTimeInterval(7200))
        history.append(watts: 20, at: start.addingTimeInterval(7200)) // Duplicate timestamps update only the last point.
        XCTAssertEqual(history.samples.count, 361)
        history.append(watts: 20, at: start.addingTimeInterval(10801)) // History expires across a long gap.
        XCTAssertEqual(history.samples.count, 1)
        history.append(watts: 30, at: start) // User sets the clock backwards.
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples[0].watts, 30)
        history.reset()
        XCTAssertEqual(history.samples.count, 0)
    }

    func testScreenChangesAndSmallDisplays() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 880)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let frame = CGRect(x: -500, y: 300, width: 304, height: 600)
        XCTAssertEqual(PanelPlacement.constrained(frame, to: [main, left]), frame)
        let moved = PanelPlacement.constrained(frame, to: [main])
        XCTAssertEqual(main.contains(moved), true)
        let tall = PanelPlacement.constrained(CGRect(x: 1300, y: 500, width: 304, height: 950), to: [main])
        XCTAssertEqual(tall.maxY, main.maxY)
        XCTAssertEqual(tall.maxX, main.maxX)
        XCTAssertEqual(PanelPlacement.constrained(frame, to: []), frame)
    }
}
