// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailmuleKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MailmuleKit", targets: ["MailmuleKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "MailmuleKit",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .testTarget(name: "MailmuleKitTests", dependencies: ["MailmuleKit"]),
    ]
)
