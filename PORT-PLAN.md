# Vulpine VPN — iOS Port Plan (v1.0)

## Architecture
Swift/SwiftUI app + NetworkExtension Packet Tunnel Provider extension.

Reimplementation of Kotlin logic in Swift:
- FxA (Firefox Account) auth: Hawk/OAuth tokens (FxaAuthRepository.kt, 363 LOC)
- Guardian control plane: vpn.mozilla.org /api/v1/fpn/{token,status,activate} (GuardianClient.kt)
- Server list: firefox.settings.services.mozilla.com vpn-serverlist records (ServerListClient.kt)
- Data plane: HTTP/2 CONNECT to Fastly edge with "proxy-authorization: Bearer <pass>"
  (URLSession + Network.framework NWProtocolHTTP/2, or raw HTTP/2 streams)
- Tunnel: NEPacketTunnelProvider (flows -> H2 CONNECT streams)
- Fastly challenge solver (cookies) — port FastlyChallengeSolver.kt

## Building
GitHub Actions macos-14 runner + Xcode: unsigned .ipa (archive + export unsigned),
user sideloads via SideStore/AltStore/Sideloadly with their Apple ID.

## Entitlement reality
NEPacketTunnelProvider needs NetworkExtension entitlement; free Apple ID sideload
provisions it via personal team (works with 7-day resign); paid dev = full.
