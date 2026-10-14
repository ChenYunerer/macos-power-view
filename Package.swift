// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PowerView",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PowerView", targets: ["PowerView"])],
    targets: [
        .target(name: "ThermalSensors", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "FanAuthorization", linkerSettings: [.linkedFramework("Security")]),
        .target(name: "FanService", linkerSettings: [.linkedFramework("Security")]),
        .target(name: "UpdateSupport", linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "PowerUpdateInstaller", dependencies: ["UpdateSupport"]),
        .target(name: "PowerCore", dependencies: ["ThermalSensors"], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "PowerFanHelper", dependencies: ["ThermalSensors"]),
        .executableTarget(name: "PowerFanDaemon", dependencies: ["ThermalSensors", "FanService"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Resources/PowerFanDaemon-Info.plist"])]),
        .executableTarget(name: "PowerView", dependencies: ["PowerCore", "FanAuthorization", "FanService", "UpdateSupport"]),
        .executableTarget(name: "PowerCoreChecks", dependencies: ["PowerCore"], path: "Tests/PowerCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
