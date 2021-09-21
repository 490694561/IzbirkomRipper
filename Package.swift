// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "IzbirkomRipper",
    platforms: [.macOS("10.15")],
    products: [
        .executable(name: "Step1DownloadUikTree", targets: ["Step1DownloadUikTree"]),
        .executable(name: "Step2ConvertUikTreeToUrlList", targets: ["Step2ConvertUikTreeToUrlList"]),
        .executable(name: "Step3DownloadHtml", targets: ["Step3DownloadHtml"]),
        .executable(name: "Step4DownloadFonts", targets: ["Step4DownloadFonts"]),
        .executable(name: "Step5ExtractFontMapping", targets: ["Step5ExtractFontMapping"]),
        .executable(name: "Step6DeoubfuscateHtml", targets: ["Step6DeoubfuscateHtml"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.5.0"),
        .package(url: "https://github.com/Ikiga/IkigaJSON.git", from: "2.0.10"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.3.3"),
    ],
    targets: [
        .target(
            name: "Step1DownloadUikTree",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "IkigaJSON", package: "IkigaJSON")
            ]),
        .target(
            name: "Step2ConvertUikTreeToUrlList",
            dependencies: [
                .product(name: "IkigaJSON", package: "IkigaJSON")
            ]),
        .target(
            name: "Step3DownloadHtml",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]),
        .target(
            name: "Step4DownloadFonts",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]),
        .target(
            name: "Step5ExtractFontMapping",
            dependencies: []),
        .target(
            name: "Step6DeoubfuscateHtml",
            dependencies: [
                "SwiftSoup"
            ]),
    ]
)
