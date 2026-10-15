// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Copy", platforms: [.macOS(.v14)],
    products: [.library(name: "CopyCore", targets: ["CopyCore"]), .executable(name: "CopyMac", targets: ["CopyMac"])],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Packages/CSQLite"),
        .target(name: "CopyCore", path: "Packages/CopyCore"),
        .target(name: "CopyStorage", dependencies: ["CopyCore", "CSQLite"], path: "Packages/CopyStorage"),
        .executableTarget(name: "CopyMac", dependencies: ["CopyCore", "CopyStorage"], path: "Apps/CopyMac", exclude: ["Info.plist", "PrivacyInfo.xcprivacy"]),
        .testTarget(name: "CopyTests", dependencies: ["CopyCore", "CopyStorage", "CopyMac", "CSQLite"], path: "Tests/CopyTests")
    ], swiftLanguageModes: [.v5]
)
