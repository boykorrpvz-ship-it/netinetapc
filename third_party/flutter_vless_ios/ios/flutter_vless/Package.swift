// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "flutter_vless",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "flutter-vless", targets: ["flutter_vless"]),
        .library(name: "flutter-vless-tunnel-support", targets: ["flutter_vless_tunnel_support"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(url: "https://github.com/EbrahimTahernejad/Tun2SocksKit", exact: "4.11.0")
    ],
    targets: [
        .target(
            name: "flutter_vless",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                "XRay"
            ],
            linkerSettings: [
                .linkedLibrary("resolv")
            ]
        ),
        .target(
            name: "flutter_vless_tunnel_support",
            dependencies: [
                "XRay",
                .product(name: "Tun2SocksKit", package: "Tun2SocksKit"),
                .product(name: "Tun2SocksKitC", package: "Tun2SocksKit")
            ],
            linkerSettings: [
                .linkedLibrary("resolv")
            ]
        ),
        .binaryTarget(
            name: "XRay",
            url: "https://github.com/XIIIFOX/flutter_vless/releases/download/xray-ios-v26.6.1/XRay.xcframework.zip",
            checksum: "13b512b31b394a701de95d1ea9ae7a8aad091d5b8d8db6d2e042374015254217"
        ),
        .testTarget(
            name: "flutter_vless_tunnel_supportTests",
            dependencies: ["flutter_vless_tunnel_support"]
        )
    ]
)
