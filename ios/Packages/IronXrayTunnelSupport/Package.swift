// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "IronXrayTunnelSupport",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(
            name: "flutter-vless-tunnel-support",
            targets: ["flutter_vless_tunnel_support"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/EbrahimTahernejad/Tun2SocksKit",
            exact: "4.11.0"
        )
    ],
    targets: [
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
            path: "Artifacts/XRay.xcframework"
        )
    ]
)
