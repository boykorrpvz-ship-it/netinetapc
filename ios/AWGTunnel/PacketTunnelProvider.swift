import NetworkExtension
import os
import WireGuardKit

private let tunnelLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "shop.ironvpn.app.AWGTunnel",
    category: "PacketTunnel"
)

private enum PacketTunnelProviderError: LocalizedError {
    case missingConfiguration
    case invalidConfiguration
    case adapter(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "AmneziaWG configuration is missing."
        case .invalidConfiguration:
            return "AmneziaWG configuration is invalid."
        case .adapter(let message):
            return message
        }
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter = WireGuardAdapter(with: self) { level, message in
        switch level {
        case .verbose:
            tunnelLog.debug("\(message, privacy: .public)")
        case .error:
            tunnelLog.error("\(message, privacy: .public)")
        }
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard
            let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
            let rawConfig = tunnelProtocol.providerConfiguration?["WgQuickConfig"] as? String
        else {
            completionHandler(PacketTunnelProviderError.missingConfiguration)
            return
        }

        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try TunnelConfiguration(
                fromWgQuickConfig: rawConfig,
                called: tunnelProtocol.serverAddress ?? "IronVPN AWG"
            )
        } catch {
            tunnelLog.error("AWG config parse failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(PacketTunnelProviderError.invalidConfiguration)
            return
        }

        adapter.start(tunnelConfiguration: tunnelConfiguration) { error in
            if let error {
                tunnelLog.error("AWG adapter start failed: \(String(describing: error), privacy: .public)")
                completionHandler(
                    PacketTunnelProviderError.adapter(String(describing: error))
                )
                return
            }

            tunnelLog.info("AmneziaWG tunnel started")
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        tunnelLog.info("Stopping AmneziaWG tunnel, reason=\(reason.rawValue, privacy: .public)")
        adapter.stop { error in
            if let error {
                tunnelLog.error("AWG adapter stop failed: \(String(describing: error), privacy: .public)")
            }
            completionHandler()
        }
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        guard messageData == Data([0]) else {
            completionHandler?(nil)
            return
        }

        adapter.getRuntimeConfiguration { settings in
            completionHandler?(settings?.data(using: .utf8))
        }
    }
}
