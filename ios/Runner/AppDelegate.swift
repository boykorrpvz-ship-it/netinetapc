import Flutter
import NetworkExtension
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "shop.ironvpn/vpn"
  private let tunnelBundleId = "shop.ironvpn.app.PacketTunnel"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result("error")
        return
      }

      switch call.method {
      case "prepare":
        result(true)
      case "start":
        guard
          let args = call.arguments as? [String: Any],
          let configJson = args["configJson"] as? String
        else {
          result("error")
          return
        }
        let profileName = (call.arguments as? [String: Any])?["profileName"] as? String ?? "IronVPN"
        self.startTunnel(profileName: profileName, configJson: configJson, result: result)
      case "stop":
        self.stopTunnel(result: result)
      case "status":
        self.status(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func startTunnel(profileName: String, configJson: String, result: @escaping FlutterResult) {
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
      guard let self, error == nil else {
        result("error")
        return
      }

      let manager = managers?.first ?? NETunnelProviderManager()
      let proto = NETunnelProviderProtocol()
      proto.providerBundleIdentifier = self.tunnelBundleId
      proto.serverAddress = profileName
      proto.providerConfiguration = ["configJson": configJson]

      manager.localizedDescription = "IronVPN"
      manager.protocolConfiguration = proto
      manager.isEnabled = true

      manager.saveToPreferences { saveError in
        if saveError != nil {
          result("error")
          return
        }

        manager.loadFromPreferences { loadError in
          if loadError != nil {
            result("error")
            return
          }

          do {
            try manager.connection.startVPNTunnel()
            result("connecting")
          } catch {
            result("error")
          }
        }
      }
    }
  }

  private func stopTunnel(result: @escaping FlutterResult) {
    NETunnelProviderManager.loadAllFromPreferences { managers, _ in
      managers?.first?.connection.stopVPNTunnel()
      result("disconnected")
    }
  }

  private func status(result: @escaping FlutterResult) {
    NETunnelProviderManager.loadAllFromPreferences { managers, _ in
      let status = managers?.first?.connection.status
      switch status {
      case .connected:
        result("connected")
      case .connecting, .reasserting:
        result("connecting")
      case .disconnecting:
        result("disconnecting")
      default:
        result("disconnected")
      }
    }
  }
}
