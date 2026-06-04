# IronVPN Mobile

Simple Flutter-based mobile client for IronVPN.

The shared Flutter layer already does the portable product flow:

- creates a payment through `https://ironvpn.shop/api/create-payment.php`;
- opens external payment confirmation;
- stores `orderId` and `accessToken` locally;
- polls `https://ironvpn.shop/api/order.php`;
- receives the customer's active subscription and `vpnLink`;
- configures the local VPN profile automatically;
- generates a sing-box TUN config;
- starts/stops VPN through native Android/iOS method channels;
- supports a `Russian services direct` routing preset.

For the customer, the active state is intentionally simple:

- subscription expiry is visible;
- one VPN on/off button;
- one `Russian services direct` toggle.

The VPN tunnel is platform-specific because mobile operating systems do not allow a pure Flutter/Dart app to create a system VPN tunnel. Android is wired to a mobile sing-box core. iOS still needs the final Network Extension/App Store setup.

## Architecture

- Flutter UI and profile logic: `lib/`
- IronVPN site API client: `lib/services/ironvpn_api.dart`
- Android VPN bridge: `android/app/src/main/kotlin/shop/ironvpn/app/`
- iOS VPN bridge: `ios/Runner/AppDelegate.swift`
- iOS Packet Tunnel stub: `ios/PacketTunnel/PacketTunnelProvider.swift`

## Build setup

Install Flutter, Android Studio and Xcode, then from this folder run:

```bash
flutter create --org shop.ironvpn --project-name ironvpn_mobile .
flutter pub get
```

If Flutter regenerates platform files, keep the custom files from this repository:

- `lib/`
- `android/app/src/main/kotlin/shop/ironvpn/app/`
- `android/app/src/main/AndroidManifest.xml`
- `ios/Runner/AppDelegate.swift`
- `ios/PacketTunnel/PacketTunnelProvider.swift`

## Native VPN status

### Android

Android uses `android.net.VpnService` plus `net.clever-vpn:libbox-android:2.1.1`.

Implemented pieces:

- native `VpnService` entry point in `IronVpnService.kt`;
- libbox lifecycle bridge in `SingBoxBridge.kt`;
- TUN creation and packet forwarding through libbox;
- DNS hijack rule in generated sing-box configs;
- one-tap start/stop state sync from Flutter.

### iOS

iOS needs a Network Extension Packet Tunnel target and the `packet-tunnel-provider` entitlement. The project contains the app-side bridge and Packet Tunnel target files, but the mobile sing-box/Xray framework still needs to be added to the Packet Tunnel target and started from:

```swift
PacketTunnelProvider.startTunnel(options:completionHandler:)
```

## Why this shape

VLESS Reality is not a standard OS VPN protocol like IKEv2 or WireGuard. The app therefore needs a userspace tunnel core plus OS-specific VPN APIs:

- Android: `VpnService`
- iOS: `NetworkExtension` Packet Tunnel Provider
- Core: sing-box or Xray mobile library

This keeps one shared app/UI and only the low-level tunnel code platform-specific.

## Payment and subscription flow

1. Customer enters email, device name and chooses a tariff.
2. App calls `create-payment.php`.
3. App stores `orderId + accessToken` before opening payment.
4. Customer pays in the external payment page.
5. On app resume, app calls `order.php`.
6. If status is `fulfilled`, app receives `vpnLink`, parses it and stores the VPN profile.

This works even if the payment page does not deep-link back to the app, because the app already has the order access pair.

## Official references

- Android `VpnService`: https://developer.android.com/reference/android/net/VpnService
- Apple `NEPacketTunnelProvider`: https://developer.apple.com/documentation/networkextension/nepackettunnelprovider
- Apple Network Extension entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_developer_networking_networkextension
- sing-box VLESS: https://sing-box.sagernet.org/configuration/outbound/vless/
- sing-box TUN: https://sing-box.sagernet.org/configuration/inbound/tun/
