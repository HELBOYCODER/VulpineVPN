// PacketTunnelProvider.swift — typealias bridge to the real provider.
// The real implementation lives in Vulpine/TunnelExtension/TunnelPacketFlowProvider.swift
// (shared into this target by project.yml) and is referenced as the extension's
// NSExtensionPrincipalClass.

typealias PacketTunnelProvider = TunnelPacketFlowProvider
