// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TesseraKit",
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
        .target(name: "TesseraStartScreen", dependencies: ["TesseraCore"]),
        .testTarget(name: "TesseraCoreTests", dependencies: ["TesseraCore"]),
        .testTarget(name: "TesseraPanoramaTests", dependencies: ["TesseraPanorama", "TesseraCore"]),
        .testTarget(name: "TesseraPivotTests", dependencies: ["TesseraPivot", "TesseraCore"]),
        .testTarget(name: "TesseraStartScreenTests", dependencies: ["TesseraStartScreen", "TesseraCore"]),
    ]
)
