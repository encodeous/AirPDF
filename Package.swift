// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = []
var targets: [Target] = [
    .target(
        name: "AirPDFCore",
        path: "Sources/AirPDFCore"
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
        name: "AirPDFMacApp",
        targets: ["AirPDFMacApp"]
    )
)
targets.append(
    .executableTarget(
        name: "AirPDFMacApp",
        dependencies: ["AirPDFCore"],
        path: "Sources/AirPDFMacApp"
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
