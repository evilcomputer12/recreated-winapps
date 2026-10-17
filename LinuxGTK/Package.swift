// swift-tools-version:5.9
import PackageDescription

// Swift + GTK4 Linux GUIs for the recreated Calculator & Paint.
// Requires libgtk-4-dev (and pkg-config). Builds on Linux; see ../.github/workflows.
let package = Package(
    name: "LinuxGTK",
    dependencies: [
        .package(path: "../CalcCoreLinux"),
    ],
    targets: [
        .systemLibrary(name: "CGtk", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
        .executableTarget(name: "gtk-calc", dependencies: [
            "CGtk", .product(name: "CalcCore", package: "CalcCoreLinux"),
        ]),
        .executableTarget(name: "gtk-paint", dependencies: ["CGtk"]),
    ]
)
