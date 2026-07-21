import Flutter
import NetworkExtension
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let awgTunnelManager = AWGTunnelManager()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "shop.ironvpn/vpn",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "APP_UNAVAILABLE", message: nil, details: nil))
        return
      }

      Task { @MainActor in
        do {
          switch call.method {
          case "deviceId":
            let value = UIDevice.current.identifierForVendor?.uuidString.lowercased()
            result(value.map { "ios-\($0)" })
          case "prepare":
            result(true)
          case "status":
            result(await self.awgTunnelManager.status())
          case "start":
            guard
              let arguments = call.arguments as? [String: Any],
              let protocolName = arguments["protocol"] as? String,
              protocolName == "amneziawg",
              let config = arguments["rawLink"] as? String,
              !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
              result(
                FlutterError(
                  code: "INVALID_AWG_CONFIG",
                  message: "AmneziaWG configuration is missing.",
                  details: nil
                )
              )
              return
            }

            let profileName = arguments["profileName"] as? String ?? "IronVPN AWG"
            try await self.awgTunnelManager.start(
              config: config,
              profileName: profileName
            )
            result(await self.awgTunnelManager.status())
          case "stop":
            await self.awgTunnelManager.stop()
            result(await self.awgTunnelManager.status())
          default:
            result(FlutterMethodNotImplemented)
          }
        } catch {
          result(
            FlutterError(
              code: "AWG_ERROR",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }
}

@MainActor
private final class AWGTunnelManager {
  private let providerBundleIdentifier = "shop.ironvpn.app.AWGTunnel"
  private var manager: NETunnelProviderManager?

  func start(config: String, profileName: String) async throws {
    let manager = try await loadManager() ?? NETunnelProviderManager()
    let tunnelProtocol = NETunnelProviderProtocol()
    tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
    tunnelProtocol.serverAddress = endpoint(from: config) ?? "IronVPN AWG"
    tunnelProtocol.providerConfiguration = ["WgQuickConfig": config]
    tunnelProtocol.excludeLocalNetworks = true

    manager.localizedDescription = profileName
    manager.protocolConfiguration = tunnelProtocol
    manager.isEnabled = true
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
    self.manager = manager
    try manager.connection.startVPNTunnel()
  }

  func stop() async {
    let manager = try? await loadManager()
    manager?.connection.stopVPNTunnel()
  }

  func status() async -> String {
    let manager = try? await loadManager()
    switch manager?.connection.status {
    case .connecting:
      return "connecting"
    case .connected, .reasserting:
      return "connected"
    case .disconnecting:
      return "disconnecting"
    case .disconnected, .invalid, nil:
      return "disconnected"
    @unknown default:
      return "error"
    }
  }

  private func loadManager() async throws -> NETunnelProviderManager? {
    if let manager {
      try await manager.loadFromPreferences()
      return manager
    }

    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    let matchingManager = managers.first { manager in
      guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol else {
        return false
      }
      return tunnelProtocol.providerBundleIdentifier == providerBundleIdentifier
    }
    self.manager = matchingManager
    return matchingManager
  }

  private func endpoint(from config: String) -> String? {
    for line in config.components(separatedBy: .newlines) {
      let parts = line.split(separator: "=", maxSplits: 1)
      guard
        parts.count == 2,
        parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "endpoint"
      else {
        continue
      }
      return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
  }
}
