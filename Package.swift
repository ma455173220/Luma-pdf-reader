// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Luma",
    platforms: [.macOS("26.0")],
    targets: [
        // Logic with no user interface: everything here can be tested without opening a window.
        .target(
            name: "LumaCore",
            linkerSettings: [.linkedLibrary("z")]
        ),
        // The application itself: windows, drawing, and input.
        .executableTarget(
            name: "Luma",
            dependencies: ["LumaCore"]
        ),
        // Runs the append writer against a folder of real PDFs and checks the results several ways.
        .executableTarget(
            name: "luma-corpus-check",
            dependencies: ["LumaCore"]
        ),
        // Scores citation decoding against an answer key made by hand (kept out of the repository).
        .executableTarget(
            name: "luma-decode-check",
            dependencies: ["LumaCore"]
        ),
        .testTarget(
            name: "LumaCoreTests",
            dependencies: ["LumaCore"],
            linkerSettings: [.linkedLibrary("z")]
        ),
        // The app's own bookkeeping of marks, tested against the real writer without opening a window.
        .testTarget(
            name: "LumaTests",
            dependencies: ["Luma", "LumaCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
