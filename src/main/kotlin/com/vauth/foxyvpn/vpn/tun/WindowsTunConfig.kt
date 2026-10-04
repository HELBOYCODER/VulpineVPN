package com.vauth.foxyvpn.vpn.tun

import com.vauth.foxyvpn.platform.FoxyPaths
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.io.File

/**
 * Generates the sing-box configuration for the Windows full-tunnel backend:
 * TUN in (gVisor mixed stack, no extra drivers) + SOCKS5 out to the app's local
 * proxy + fake-DNS (mapdns equivalent) + explicit bypass routes so the engine's
 * own control-plane and edge sockets never re-enter the tunnel.
 */
object WindowsTunConfig {
    const val TUN_ADDRESS = "10.8.0.2"
    private const val FAKEIP_NETWORK = "100.64.0.0/10"

    private const val MAPDNS_NETWORK_BITS = 100L shl 24 or (64L shl 16)
    private const val MAPDNS_NETMASK_BITS = 255L shl 24 or (192L shl 16)

    fun isFakeDnsAddress(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size != 4) return false
        var packed = 0L
        for (part in parts) {
            if (part.isEmpty() || part.length > 3) return false
            val octet = part.toIntOrNull() ?: return false
            if (octet !in 0..255) return false
            packed = (packed shl 8) or octet.toLong()
        }
        return (packed and MAPDNS_NETMASK_BITS) == MAPDNS_NETWORK_BITS
    }

    fun write(socksPort: Int, dohEndpointAddresses: List<String>, bypassIps: List<String>): String {
        val bootstrapAddress = dohEndpointAddresses.firstOrNull() ?: "1.1.1.1"
        val bypass = buildList {
            addAll(bypassIps)
            add(bootstrapAddress)
            addAll(dohEndpointAddresses)
            add("127.0.0.0/8")
        }.distinct()

        val dns = buildJsonObject {
            put(
                "servers",
                buildJsonArray {
                    add(
                        buildJsonObject {
                            put("type", "fakeip")
                            put("tag", "dns-fakeip")
                            put("inet4_range", FAKEIP_NETWORK)
                        },
                    )
                    add(
                        buildJsonObject {
                            put("type", "udp")
                            put("tag", "dns-bootstrap")
                            put("server", bootstrapAddress)
                        },
                    )
                    add(
                        buildJsonObject {
                            put("type", "https")
                            put("tag", "dns-upstream")
                            put("server", "https://dns.cloudflare.com/dns-query")
                            put("detour", "tun-socks")
                        },
                    )
                },
            )
            put(
                "rules",
                buildJsonArray {
                    add(
                        buildJsonObject {
                            put("action", "route")
                            put("server", "dns-bootstrap")
                            put(
                                "domain_suffix",
                                buildJsonArray {
                                    add(JsonPrimitive("mozilla.org"))
                                    add(JsonPrimitive("mozilla.com"))
                                    add(JsonPrimitive("firefox.com"))
                                    add(JsonPrimitive("cloudflare.com"))
                                },
                            )
                        },
                    )
                    add(
                        buildJsonObject {
                            put("action", "route")
                            put("server", "dns-fakeip")
                            put("query_type", buildJsonArray { add(JsonPrimitive("A")); add(JsonPrimitive("AAAA")) })
                        },
                    )
                },
            )
            put("final", "dns-upstream")
        }

        val config = buildJsonObject {
            putJsonObject("log") {
                put("level", "info")
                put("timestamp", true)
                put("output", File(FoxyPaths.helperDir, "singbox.log").absolutePath)
            }
            put("dns", dns)
            put(
                "inbounds",
                buildJsonArray {
                    add(
                        buildJsonObject {
                            put("type", "tun")
                            put("tag", "tun-in")
                            put("address", buildJsonArray { add(JsonPrimitive("$TUN_ADDRESS/24")) })
                            put("mtu", 1500)
                            put("auto_route", true)
                            put("strict_route", false)
                            put("stack", "mixed")
                        },
                    )
                },
            )
            putJsonObject("route") {
                put(
                    "rules",
                    buildJsonArray {
                        add(
                            buildJsonObject {
                                put("action", "hijack-dns")
                                put("protocol", buildJsonArray { add(JsonPrimitive("dns")) })
                            },
                        )
                        add(
                            buildJsonObject {
                                put("action", "route")
                                put(
                                    "ip_cidr",
                                    JsonArray(bypass.map { JsonPrimitive(if (it.contains('/')) it else "$it/32") }),
                                )
                                put("outbound", "direct-bypass")
                            },
                        )
                    },
                )
                put("final", "tun-socks")
                put("default_domain_resolver", "dns-bootstrap")
                put("auto_detect_interface", true)
            }
            putJsonObject("experimental") {
                putJsonObject("cache_file") {
                    put("enabled", true)
                    put("path", File(FoxyPaths.helperDir, "singbox-cache.db").absolutePath)
                }
            }
            put(
                "outbounds",
                buildJsonArray {
                    add(
                        buildJsonObject {
                            put("type", "socks")
                            put("tag", "tun-socks")
                            put("server", "127.0.0.1")
                            put("server_port", socksPort)
                            put("version", "5")
                        },
                    )
                    add(
                        buildJsonObject {
                            put("type", "direct")
                            put("tag", "direct-bypass")
                        },
                    )
                },
            )
        }

        val file = File(FoxyPaths.helperDir, "singbox-windows.json")
        file.parentFile?.mkdirs()
        file.writeText(config.toString())
        return file.absolutePath
    }
}
