package shop.ironvpn.app

// Each VPN engine gets a dedicated service pinned to its own process (see the
// android:process attributes in AndroidManifest). The sing-box (VLESS) and
// AmneziaWG engines are both gomobile libraries that bundle their own Go
// runtime; activating a second Go runtime in a process that already activated
// the other one crashes natively (SIGSEGV). Keeping each engine in its own
// process guarantees a process only ever activates a single runtime, so VPN
// type switches no longer crash — and, unlike killing a shared process between
// switches, the processes stay alive/cached and are never flagged as a "bad
// process" by OEM task killers (which previously caused "Ошибка запуска").

/** Hosts the sing-box / VLESS engine. */
class BoxVpnService : IronVpnService()

/** Hosts the AmneziaWG engine. */
class AwgVpnService : IronVpnService()
