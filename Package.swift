// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IPadScreenMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "IPadScreenMac", targets: ["IPadScreenMac"])],
    targets: [
        .target(name: "VirtualDisplay", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "IPadScreenCore", dependencies: ["VirtualDisplay"]),
        .executableTarget(name: "IPadScreenMac", dependencies: ["IPadScreenCore", "VirtualDisplay"]),
        .testTarget(name: "IPadScreenCoreTests", dependencies: ["IPadScreenCore"])
    ]
)
