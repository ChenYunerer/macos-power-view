// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PowerView",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PowerView", targets: ["PowerView"])],
    targets: [
        .target(name: "ThermalSensors", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "FanAuthorization", linkerSettings: [.linkedFramework("Security")]),
        .target(name: "PowerCore", dependencies: ["ThermalSensors"], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "PowerFanHelper", dependencies: ["ThermalSensors"]),
        .executableTarget(name: "PowerView", dependencies: ["PowerCore", "FanAuthorization"]),
        .executableTarget(name: "PowerCoreChecks", dependencies: ["PowerCore"], path: "Tests/PowerCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
