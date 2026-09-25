// swift-tools-version: 6.0
// Инструменты сборки с закреплёнными версиями: XcodeGen собирается из исходников,
// без Homebrew, одинаково на Mac и в CI. Запуск — scripts/generate-project.sh.
import PackageDescription

let package = Package(
    name: "BuildTools",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/yonaskolb/XcodeGen.git", exact: "2.46.0"),
    ],
    targets: [
        .target(name: "BuildTools", path: "Sources/BuildTools"),
    ]
)
