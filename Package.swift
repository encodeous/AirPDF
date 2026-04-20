// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = []
var targets: [Target] = [
    .target(
        name: "AirPDFCore",
        path: "Sources/Core"
    ),
    .testTarget(
        name: "AirPDFCoreTests",
        dependencies: ["AirPDFCore"],
        path: "Tests/AirPDFCoreTests"
    )
]

#if os(macOS)
products.append(
    .executable(
        name: "AirPDF",
        targets: ["AirPDFMacApp"]
    )
)
targets.append(
    .executableTarget(
        name: "AirPDFMacApp",
        dependencies: ["AirPDFCore"],
        path: "Sources/macOS"
    )
)
#endif

let package = Package(
    name: "AirPDF",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
