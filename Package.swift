// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LumeBar",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "LumeBar", targets: ["LumeBar"])
    ],
    dependencies: [
        .package(url: "https://github.com/royalapplications/royalvnc.git", revision: "3b01b5a113592b2826ececf290067ff50236c536")
    ],
    targets: [
        .executableTarget(
            name: "LumeBar",
            dependencies: [
                .product(name: "RoyalVNCKit", package: "royalvnc")
            ],
            path: "Sources/LumeBar",
            exclude: [
                "Resources/Info.plist"
            ],
            resources: [
                .process("Resources/Assets.xcassets")
            ]
        ),
        .testTarget(name: "LumeBarTests", dependencies: ["LumeBar"])
    ]
)
