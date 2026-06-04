import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private var configJson: String?

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol
    configJson = tunnelProtocol?.providerConfiguration?["configJson"] as? String

    let error = NSError(
      domain: "shop.ironvpn.app",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Add sing-box or Xray mobile framework to PacketTunnelProvider before enabling the tunnel."
      ]
    )
    completionHandler(error)
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }
}
