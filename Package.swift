// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clips2",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Clips2",
            path: "Sources/Clips2",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Speech"),
                .linkedFramework("CoreText"),
            ]
        )
    ]
)
