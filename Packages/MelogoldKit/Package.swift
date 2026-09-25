// swift-tools-version: 6.2
// MelogoldKit — всё, что не интерфейс: правила, InnerTube, сервер и синк, база, плеер (docs/PROMPT.md §3).
// Собирается для iOS, macOS, visionOS и watchOS; `swift test` гоняет правила и векторы без симулятора.
import PackageDescription

let strictSwift: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "MelogoldKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "MelogoldCore", targets: ["MelogoldCore"]),
        .library(name: "MelogoldData", targets: ["MelogoldData"]),
        .library(name: "MelogoldInnerTube", targets: ["MelogoldInnerTube"]),
        .library(name: "MelogoldServer", targets: ["MelogoldServer"]),
        .library(name: "MelogoldPlayback", targets: ["MelogoldPlayback"]),
    ],
    targets: [
        .target(name: "MelogoldCore", swiftSettings: strictSwift),
        .target(name: "MelogoldData", dependencies: ["MelogoldCore"], swiftSettings: strictSwift),
        .target(name: "MelogoldInnerTube", dependencies: ["MelogoldCore"], swiftSettings: strictSwift),
        .target(name: "MelogoldServer", dependencies: ["MelogoldCore", "MelogoldData"], swiftSettings: strictSwift),
        .target(
            name: "MelogoldPlayback",
            dependencies: ["MelogoldCore", "MelogoldData", "MelogoldInnerTube"],
            swiftSettings: strictSwift
        ),
        .testTarget(name: "MelogoldCoreTests", dependencies: ["MelogoldCore"], swiftSettings: strictSwift),
        .testTarget(name: "MelogoldDataTests", dependencies: ["MelogoldData"], swiftSettings: strictSwift),
    ]
)
