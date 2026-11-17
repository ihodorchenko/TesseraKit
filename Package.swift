// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TesseraKit",
    // TesseraStartScreen ships localized resources
    // (en/ru Localizable.strings), so SPM requires an explicit default localization.
    defaultLocalization: "en",
    platforms: [.iOS(.v15), .macCatalyst(.v15)],
    products: [
        .library(name: "TesseraCore", targets: ["TesseraCore"]),
        .library(name: "TesseraPanorama", targets: ["TesseraPanorama"]),
        .library(name: "TesseraPivot", targets: ["TesseraPivot"]),
        .library(name: "TesseraStartScreen", targets: ["TesseraStartScreen"]),
    ],
    targets: [
        .target(name: "TesseraCore"),
        .target(name: "TesseraPanorama", dependencies: ["TesseraCore"]),
        .target(name: "TesseraPivot", dependencies: ["TesseraCore"]),
        // Default strings are SPM resources; the public API is unchanged.
        .target(
            name: "TesseraStartScreen",
            dependencies: ["TesseraCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "TesseraCoreTests", dependencies: ["TesseraCore"]),
        .testTarget(name: "TesseraPanoramaTests", dependencies: ["TesseraPanorama", "TesseraCore"]),
        .testTarget(name: "TesseraPivotTests", dependencies: ["TesseraPivot", "TesseraCore"]),
        .testTarget(name: "TesseraStartScreenTests", dependencies: ["TesseraStartScreen", "TesseraCore"]),
    ]
)
