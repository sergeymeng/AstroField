// swift-tools-version: 5.10
import PackageDescription
import Foundation

// The app uses ImageCaptureCore. MAID is an optional backend for the CLI.
let nikonHeaders = ProcessInfo.processInfo.environment["NIKON_SDK_HEADERS"]
let sdkEnabled = nikonHeaders != nil
if let nikonHeaders {
    precondition(FileManager.default.fileExists(atPath: nikonHeaders + "/Maid3.h"),
                 "NIKON_SDK_HEADERS must point to the SDK's Mac/HeaderFile directory")
}
let sdkDependencies: [Target.Dependency] = sdkEnabled ? ["CNikonMAID"] : []
let sdkSettings: [SwiftSetting] = sdkEnabled ? [.define("ASTROFIELD_NIKON_SDK")] : []

let package = Package(
    name: "AstroField",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "afspike", targets: ["afspike"]),
        .executable(name: "AstroField", targets: ["AstroField"])
    ],
    targets: (sdkEnabled ? [
        .target(
            name: "CNikonMAID",
            path: "Sources/CNikonMAID",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-I", nikonHeaders!
                ])
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("ImageCaptureCore")
            ]
        )
    ] : []) + [
        .target(
            name: "AFSpikeCore",
            dependencies: sdkDependencies,
            path: "Sources/AFSpikeCore",
            swiftSettings: sdkSettings
        ),
        .target(
            name: "AstroFieldKit",
            dependencies: ["AFSpikeCore"],
            path: "Sources/AstroFieldKit"
        ),
        .executableTarget(
            name: "AstroField",
            dependencies: ["AstroFieldKit", "AFSpikeCore"],
            path: "Sources/AstroField",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .executableTarget(
            name: "afspike",
            dependencies: ["AFSpikeCore"] + sdkDependencies,
            path: "Sources/afspike",
            swiftSettings: sdkSettings,
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "AFSpikeCoreTests",
            dependencies: ["AFSpikeCore"],
            path: "Tests/AFSpikeCoreTests"
        ),
        .testTarget(
            name: "AstroFieldKitTests",
            dependencies: ["AstroFieldKit"],
            path: "Tests/AstroFieldKitTests"
        )
    ]
)
