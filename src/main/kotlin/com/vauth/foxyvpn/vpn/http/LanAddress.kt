package com.vauth.foxyvpn.vpn.http

import com.vauth.foxyvpn.data.AppLogger
import java.net.NetworkInterface

private const val TAG = "LanAddress"

data class LanEndpoint(val name: String, val address: String)

/**
 * IPv4 addresses a phone on the same network could reach this machine at. Link-local and
 * loopback addresses are skipped: iOS would never route through them.
 */
fun lanEndpoints(): List<LanEndpoint> {
    return runCatching {
        NetworkInterface.getNetworkInterfaces().asSequence()
            .filter { it.isUp && !it.isLoopback && !it.isVirtual }
            .flatMap { nic ->
                nic.inetAddresses.asSequence()
                    .filter { address ->
                        address.hostAddress?.let { it.contains('.') && !it.startsWith("127.") && !it.startsWith("169.254.") } == true
                    }
                    .map { LanEndpoint(nic.name, it.hostAddress) }
            }
            .toList()
    }.onFailure { AppLogger.w(TAG, "could not enumerate network interfaces", it) }.getOrElse { emptyList() }
}

fun firstLanEndpoint(): LanEndpoint? =
    lanEndpoints().firstOrNull { it.name.startsWith("en") } ?: lanEndpoints().firstOrNull()

fun hostName(): String = runCatching { java.net.InetAddress.getLocalHost().hostName }
    .getOrDefault("Vulpine VPN")
