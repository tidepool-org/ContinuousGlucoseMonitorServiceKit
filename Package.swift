// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ContinuousGlucoseMonitorServiceKit",
    defaultLocalization: "en",
    platforms: [.iOS("17.6")],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "ContinuousGlucoseMonitorServiceKit",
            targets: ["ContinuousGlucoseMonitorServiceKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tidepool-org/BluetoothCommonKit.git", branch: "dev")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "ContinuousGlucoseMonitorServiceKit",
            dependencies: ["BluetoothCommonKit"]),
        .testTarget(
            name: "ContinuousGlucoseMonitorServiceKitTests",
            dependencies: ["ContinuousGlucoseMonitorServiceKit"]
        ),
    ]
)
