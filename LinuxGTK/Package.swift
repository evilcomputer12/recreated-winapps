// swift-tools-version:5.9
import PackageDescription

// Linux GUIs for Calculator & Paint: native windows (GTK3) hosting a WebKit2GTK
// web view that renders the exact same polished HTML/CSS UI as the web build,
// so the look is pixel-identical and theme-independent.
// Requires webkit2gtk-4.1 (+ gtk3). Build on Linux.
let package = Package(
    name: "LinuxGTK",
    targets: [
        .systemLibrary(name: "CWeb", pkgConfig: "webkit2gtk-4.1", providers: [.apt(["libwebkit2gtk-4.1-dev"])]),
        .executableTarget(name: "gtk-calc", dependencies: ["CWeb"]),
        .executableTarget(name: "gtk-paint", dependencies: ["CWeb"]),
    ]
)
