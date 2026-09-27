package com.vauth.foxyvpn.vpn.http

import com.vauth.foxyvpn.data.AppLogger
import java.io.File
import java.util.UUID

private const val TAG = "IosProfile"

private const val PAYLOAD_TYPE = "com.apple.proxy.http.global"

/**
 * iOS configuration profile that points the device's global HTTP proxy at this machine.
 * Apple only honours this payload on supervised devices; on a personal iPhone the same
 * settings are entered by hand (see manualSteps), which is why the exporter is advisory.
 */
object IosProfile {

    fun build(server: String, port: Int, deviceLabel: String): String {
        val profileUuid = UUID.randomUUID().toString()
        val payloadUuid = UUID.randomUUID().toString()
        val identifier = "com.vauth.foxyvpn.iosproxy"
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>PayloadContent</key>
                <array>
                    <dict>
                        <key>PayloadIdentifier</key><string>$identifier.$payloadUuid</string>
                        <key>PayloadType</key><string>$PAYLOAD_TYPE</string>
                        <key>PayloadUUID</key><string>$payloadUuid</string>
                        <key>PayloadVersion</key><integer>1</integer>
                        <key>ProxyType</key><string>Manual</string>
                        <key>ProxyServer</key><string>${xml(server)}</string>
                        <key>ProxyServerPort</key><integer>$port</integer>
                        <key>ProxyCaptiveLoginAllowed</key><false/>
                    </dict>
                </array>
                <key>PayloadDisplayName</key><string>Vulpine VPN proxy ($deviceLabel)</string>
                <key>PayloadIdentifier</key><string>$identifier</string>
                <key>PayloadOrganization</key><string>vauth</string>
                <key>PayloadRemovalDisallowed</key><false/>
                <key>PayloadType</key><string>Configuration</string>
                <key>PayloadUUID</key><string>$profileUuid</string>
                <key>PayloadVersion</key><integer>1</integer>
            </dict>
            </plist>
        """.trimIndent() + "\n"
    }

    fun writeFile(server: String, port: Int, deviceLabel: String): File {
        val downloads = File(System.getProperty("user.home"), "Downloads")
        val target = File(downloads, "VulpineProxy-$server.mobileconfig".replace(' ', '_'))
        runCatching { target.parentFile?.mkdirs() }
        target.writeText(build(server, port, deviceLabel))
        AppLogger.i(TAG, "wrote iOS profile for $server:$port to ${target.absolutePath}")
        return target
    }

    fun manualSteps(server: String, port: Int): String = """
        On the iPhone (same Wi-Fi as this Mac):
        1. Settings > Wi-Fi > (i) next to your network
        2. HTTP Proxy > Manual
        3. Server: $server
        4. Port: $port
        5. Leave Authentication off
        Apps that honour the Wi-Fi proxy now run through Vulpine.
        Set the proxy back to Off when you disconnect.
    """.trimIndent()

    private fun xml(value: String): String = value
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
}
