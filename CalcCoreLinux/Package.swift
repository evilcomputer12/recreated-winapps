// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "calc",
    products: [
        .library(name: "CalcCore", targets: ["CalcCore"]),
        .executable(name: "calc", targets: ["calc"]),
    ],
    targets: [
        .target(name: "CalcCore"),
        .executableTarget(name: "calc", dependencies: ["CalcCore"]),
    ]
)
