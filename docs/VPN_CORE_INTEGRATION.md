# VPN core integration

The app receives the customer's VLESS Reality profile from the IronVPN site API and generates `configJson`.

Android is already connected to a mobile sing-box core through `libbox-android`. iOS still needs the final Packet Tunnel core integration and Apple entitlement setup.

## Core

The project uses sing-box on Android:

- supports VLESS Reality;
- has a TUN inbound;
- uses one JSON config shape for Android and iOS;
- keeps most routing logic in the shared Flutter layer.

Xray-core is also possible, but the mobile integration tends to require more platform-specific wrapper work.

## Android implementation

Implemented files:

```text
android/app/src/main/kotlin/shop/ironvpn/app/IronVpnService.kt
android/app/src/main/kotlin/shop/ironvpn/app/SingBoxBridge.kt
```

Android uses:

- `android.net.VpnService` for system VPN permission and TUN creation;
- `net.clever-vpn:libbox-android:2.1.1` for packet processing;
- `SingBoxBridge.start()` / `stop()` for the native lifecycle;
- `SingBoxBridge.isRunning()` for Flutter state sync.

Do not create a dummy `VpnService.Builder().establish()` without forwarding packets. That would show a VPN icon but break the user's internet.

## iOS implementation point

File:

```text
ios/PacketTunnel/PacketTunnelProvider.swift
```

Replace the current safe error with:

```swift
let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol
let configJson = tunnelProtocol?.providerConfiguration?["configJson"] as? String
// Start sing-box/Xray mobile framework with configJson.
```

The Packet Tunnel target needs:

- App Groups if the main app and extension share files;
- `com.apple.developer.networking.networkextension`;
- `packet-tunnel-provider` entitlement;
- a paid Apple Developer account for device/App Store distribution.

## Routing preset

The Flutter layer generates configs with a DNS hijack rule and can route Russian services directly. The current direct preset includes:

- Ozon, Wildberries, Avito;
- Gosuslugi, Yandex, Mail, VK;
- major Russian banks;
- FACEIT and Steam domains.

This can be changed in:

```text
lib/models/vless_profile.dart
```
