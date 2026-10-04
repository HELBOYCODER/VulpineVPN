package com.vauth.foxyvpn.ui.screens

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.vauth.foxyvpn.BuildConfig
import com.vauth.foxyvpn.data.SettingsStore

private const val GITHUB_URL = "https://github.com/vauth/foxyvpn"

@Composable
fun SettingsScreen(
    settingsStore: SettingsStore,
    onOpenLogs: () -> Unit,
    onOpenAccount: () -> Unit,
    onSignOut: () -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    var exitCheckEnabled by remember { mutableStateOf(settingsStore.exitCheckEnabled) }
    var dohProvider by remember { mutableStateOf(settingsStore.dohProvider) }
    var customDnsEnabled by remember { mutableStateOf(settingsStore.customDnsEnabled) }
    var customDnsServer by remember { mutableStateOf(settingsStore.customDnsServer) }
    var socksBindAddress by remember { mutableStateOf(settingsStore.socksBindAddress) }
    var socksPort by remember { mutableStateOf(settingsStore.socksPort) }
    var proxyOnlyMode by remember { mutableStateOf(settingsStore.proxyOnlyMode) }
    var macTrafficMode by remember { mutableStateOf(settingsStore.macTrafficMode) }
    var showTrafficModeDialog by remember { mutableStateOf(false) }
    var customEdgeAddress by remember { mutableStateOf(settingsStore.customEdgeAddress) }
    var upstreamProxyEnabled by remember { mutableStateOf(settingsStore.upstreamProxyEnabled) }
    var upstreamProxyType by remember { mutableStateOf(settingsStore.upstreamProxyType) }
    var upstreamProxyHost by remember { mutableStateOf(settingsStore.upstreamProxyHost) }
    var upstreamProxyPort by remember { mutableStateOf(settingsStore.upstreamProxyPort) }
    var upstreamProxyUsername by remember { mutableStateOf(settingsStore.upstreamProxyUsername) }
    var upstreamProxyPassword by remember { mutableStateOf(settingsStore.upstreamProxyPassword) }
    var excludedApps by remember { mutableStateOf(settingsStore.excludedApps) }
    var showDohProviderDialog by remember { mutableStateOf(false) }
    var showCustomDnsDialog by remember { mutableStateOf(false) }
    var showSocksBindDialog by remember { mutableStateOf(false) }
    var showSocksPortDialog by remember { mutableStateOf(false) }
    var showIosShareDialog by remember { mutableStateOf(false) }
    var showIosPortDialog by remember { mutableStateOf(false) }
    var iosShareEnabled by remember { mutableStateOf(settingsStore.iosShareEnabled) }
    var iosSharePort by remember { mutableStateOf(settingsStore.iosSharePort) }
    val lanEndpoint = remember(showIosShareDialog, iosSharePort, iosShareEnabled) {
        com.vauth.foxyvpn.vpn.http.firstLanEndpoint()
    }
    var showEdgeAddressDialog by remember { mutableStateOf(false) }
    var showUpstreamProxyTypeDialog by remember { mutableStateOf(false) }
    var showUpstreamProxyAddressDialog by remember { mutableStateOf(false) }
    var showUpstreamProxyCredentialsDialog by remember { mutableStateOf(false) }
    var showSplitTunnelDialog by remember { mutableStateOf(false) }

    if (showDohProviderDialog) {
        DohProviderPickerDialog(
            current = dohProvider,
            onDismiss = { showDohProviderDialog = false },
            onConfirm = {
                dohProvider = it
                settingsStore.dohProvider = it
                showDohProviderDialog = false
            },
        )
    }
    if (showCustomDnsDialog) {
        CustomDnsPickerDialog(
            current = customDnsServer,
            onDismiss = { showCustomDnsDialog = false },
            onConfirm = {
                customDnsServer = it
                settingsStore.customDnsServer = it
                showCustomDnsDialog = false
            },
        )
    }
    if (showSocksBindDialog) {
        SocksBindAddressPickerDialog(
            current = socksBindAddress,
            onDismiss = { showSocksBindDialog = false },
            onConfirm = {
                socksBindAddress = it
                settingsStore.socksBindAddress = it
                showSocksBindDialog = false
            },
        )
    }
    if (showSocksPortDialog) {
        SocksPortPickerDialog(
            current = socksPort,
            onDismiss = { showSocksPortDialog = false },
            onConfirm = {
                socksPort = it
                settingsStore.socksPort = it
                showSocksPortDialog = false
            },
        )
    }
    if (showIosPortDialog) {
        SocksPortPickerDialog(
            current = iosSharePort,
            onDismiss = { showIosPortDialog = false },
            onConfirm = {
                iosSharePort = it
                settingsStore.iosSharePort = it
                showIosPortDialog = false
            },
        )
    }
    if (showIosShareDialog) {
        IosShareDialog(
            lanAddress = lanEndpoint?.address,
            interfaceName = lanEndpoint?.name,
            port = iosSharePort,
            onDismiss = { showIosShareDialog = false },
        )
    }
    if (showEdgeAddressDialog) {
        CustomEdgeAddressDialog(
            current = customEdgeAddress,
            onDismiss = { showEdgeAddressDialog = false },
            onConfirm = {
                customEdgeAddress = it
                settingsStore.customEdgeAddress = it
                showEdgeAddressDialog = false
            },
        )
    }
    if (showUpstreamProxyTypeDialog) {
        UpstreamProxyTypePickerDialog(
            current = upstreamProxyType,
            onDismiss = { showUpstreamProxyTypeDialog = false },
            onConfirm = {
                upstreamProxyType = it
                settingsStore.upstreamProxyType = it
                showUpstreamProxyTypeDialog = false
            },
        )
    }
    if (showUpstreamProxyAddressDialog) {
        UpstreamProxyAddressDialog(
            currentHost = upstreamProxyHost,
            currentPort = upstreamProxyPort,
            onDismiss = { showUpstreamProxyAddressDialog = false },
            onConfirm = { host, port ->
                upstreamProxyHost = host
                upstreamProxyPort = port
                settingsStore.upstreamProxyHost = host
                settingsStore.upstreamProxyPort = port
                showUpstreamProxyAddressDialog = false
            },
        )
    }
    if (showUpstreamProxyCredentialsDialog) {
        UpstreamProxyCredentialsDialog(
            currentUsername = upstreamProxyUsername,
            currentPassword = upstreamProxyPassword,
            onDismiss = { showUpstreamProxyCredentialsDialog = false },
            onConfirm = { username, password ->
                upstreamProxyUsername = username
                upstreamProxyPassword = password
                settingsStore.upstreamProxyUsername = username
                settingsStore.upstreamProxyPassword = password
                showUpstreamProxyCredentialsDialog = false
            },
        )
    }
    if (showSplitTunnelDialog) {
        SplitTunnelDialog(
            current = excludedApps,
            onDismiss = { showSplitTunnelDialog = false },
            onConfirm = {
                excludedApps = it
                settingsStore.excludedApps = it
                showSplitTunnelDialog = false
            },
        )
    }

    if (showTrafficModeDialog) {
        TrafficModePickerDialog(
            current = macTrafficMode,
            onDismiss = { showTrafficModeDialog = false },
            onConfirm = {
                macTrafficMode = it
                settingsStore.macTrafficMode = it
                showTrafficModeDialog = false
            },
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState()),
        ) {
            SectionLabel("Connection")
            ListItem(
                headlineContent = { Text("Verify exit location") },
                supportingContent = { Text("Check that the tunnel exits in the selected country") },
                trailingContent = {
                    Switch(
                        checked = exitCheckEnabled,
                        onCheckedChange = {
                            exitCheckEnabled = it
                            settingsStore.exitCheckEnabled = it
                        },
                    )
                },
            )

            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            SectionLabel("DNS")
            ListItem(
                headlineContent = { Text("Encrypted DNS") },
                supportingContent = { Text(dohProvider.label) },
                trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                modifier = Modifier.clickable { showDohProviderDialog = true },
            )
            ListItem(
                headlineContent = { Text("Use a custom DNS server") },
                supportingContent = { Text("Send your apps' DNS queries to a server you choose") },
                trailingContent = {
                    Switch(
                        checked = customDnsEnabled,
                        onCheckedChange = {
                            customDnsEnabled = it
                            settingsStore.customDnsEnabled = it
                        },
                    )
                },
            )
            if (customDnsEnabled) {
                ListItem(
                    headlineContent = { Text("DNS server") },
                    supportingContent = {
                        val presetLabel = SettingsStore.CUSTOM_DNS_PRESETS
                            .firstOrNull { it.first == customDnsServer }
                            ?.second
                        Text(presetLabel ?: customDnsServer)
                    },
                    trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                    modifier = Modifier.clickable { showCustomDnsDialog = true },
                )
            }

            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            SectionLabel("Local proxy")
            ListItem(
                headlineContent = { Text("Proxy-only mode") },
                supportingContent = { Text("Run only the local SOCKS5 proxy, without changing the system proxy") },
                trailingContent = {
                    Switch(
                        checked = proxyOnlyMode,
                        onCheckedChange = {
                            proxyOnlyMode = it
                            settingsStore.proxyOnlyMode = it
                        },
                    )
                },
            )
            if (com.vauth.foxyvpn.platform.Os.isWindows && !proxyOnlyMode) {
                ListItem(
                    headlineContent = { Text("Traffic capture") },
                    supportingContent = {
                        Text(
                            when (macTrafficMode) {
                                SettingsStore.MacTrafficMode.GLOBAL_TUN ->
                                    "Full tunnel: all system traffic (IPv4/IPv6) through the VPN"
                                else -> "System proxy: browsers and apps that honor Windows proxy settings"
                            },
                        )
                    },
                    trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                    modifier = Modifier.clickable { showTrafficModeDialog = true },
                )
            }
            ListItem(
                headlineContent = { Text("Local address") },
                supportingContent = { Text(socksBindAddress) },
                trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                modifier = Modifier.clickable { showSocksBindDialog = true },
            )
            ListItem(
                headlineContent = { Text("Local port") },
                supportingContent = { Text(socksPort.toString()) },
                trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                modifier = Modifier.clickable { showSocksPortDialog = true },
            )

            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            SectionLabel("Share with a phone")
            ListItem(
                headlineContent = { Text("iOS / laptop proxy") },
                supportingContent = {
                    Text(
                        if (iosShareEnabled) {
                            val address = lanEndpoint?.address
                            if (address == null) {
                                "Waiting for a local-network address on this Mac"
                            } else {
                                "Devices on this network can use the VPN over HTTP at $address:$iosSharePort"
                            }
                        } else {
                            "Publish an HTTP proxy on the local network so an iPhone can use this VPN"
                        },
                    )
                },
                trailingContent = {
                    Switch(
                        checked = iosShareEnabled,
                        onCheckedChange = {
                            iosShareEnabled = it
                            settingsStore.iosShareEnabled = it
                            com.vauth.foxyvpn.vpn.FoxyVpnService.applyIosShare(it)
                        },
                    )
                },
            )
            if (iosShareEnabled) {
                ListItem(
                    headlineContent = { Text("Address and steps") },
                    supportingContent = { Text("How to point an iPhone at this Mac") },
                    trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                    modifier = Modifier.clickable { showIosShareDialog = true },
                )
                ListItem(
                    headlineContent = { Text("Share port") },
                    supportingContent = { Text(iosSharePort.toString()) },
                    trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                    modifier = Modifier.clickable { showIosPortDialog = true },
                )
            }

            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            SectionLabel("Split tunneling")
            ListItem(
                headlineContent = { Text("Excluded apps") },
                supportingContent = {
                    Text(
                        if (excludedApps.isEmpty()) {
                            "None"
                        } else {
                            "${excludedApps.size} app(s) bypass the VPN"
                        },
                    )
                },
                trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                modifier = Modifier.clickable { showSplitTunnelDialog = true },
            )

            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            SectionLabel("Advanced")
            ListItem(
                headlineContent = { Text("Custom edge address") },
                supportingContent = { Text(customEdgeAddress.ifBlank { "Not set" }) },
                trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                modifier = Modifier.clickable { showEdgeAddressDialog = true },
            )
            ListItem(
                headlineContent = { Text("Chain through upstream proxy") },
                supportingContent = { Text("Connect to the VPN server through another proxy first") },
                trailingContent = {
                    Switch(
                        checked = upstreamProxyEnabled,
                        onCheckedChange = {
                            upstreamProxyEnabled = it
                            settingsStore.upstreamProxyEnabled = it
                        },
                    )
                },
            )
            if (upstreamProxyEnabled) {
                ListItem(
                    headlineContent = { Text("Proxy type") },
                    supportingContent = { Text(upstreamProxyType.name) },
                    trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                    modifier = Modifier.clickable { showUpstreamProxyTypeDialog = true },
                )
                ListItem(
                    headlineContent = { Text("Proxy address") },
                    supportingContent = {
                        Text(
                            if (upstreamProxyHost.isBlank()) {
                                "Not set"
                            } else {
                                "$upstreamProxyHost:$upstreamProxyPort"
                            },
                        )
                    },
                    trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                    modifier = Modifier.clickable { showUpstreamProxyAddressDialog = true },
                )
                ListItem(
                    headlineContent = { Text("Proxy credentials") },
                    supportingContent = {
                        Text(if (upstreamProxyUsername.isBlank()) "None" else upstreamProxyUsername)
                    },
                    trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                    modifier = Modifier.clickable { showUpstreamProxyCredentialsDialog = true },
                )
            }

            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            SectionLabel("About")
            ListItem(
                headlineContent = { Text("View logs") },
                supportingContent = { Text("Recent connection activity") },
                trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                modifier = Modifier.clickable(onClick = onOpenLogs),
            )
            ListItem(
                headlineContent = { Text("Version") },
                supportingContent = { Text(BuildConfig.VERSION_NAME) },
            )
            ListItem(
                headlineContent = { Text("Source code") },
                supportingContent = { Text(GITHUB_URL) },
                leadingContent = { Icon(Icons.Filled.Code, contentDescription = null) },
                modifier = Modifier.clickable {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(GITHUB_URL)))
                },
            )

            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            SectionLabel("Account")
            ListItem(
                headlineContent = { Text("Manage account") },
                supportingContent = { Text("Subscription status and data usage") },
                leadingContent = { Icon(Icons.Filled.AccountCircle, contentDescription = null) },
                trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                modifier = Modifier.clickable(onClick = onOpenAccount),
            )
            Button(
                onClick = onSignOut,
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.errorContainer,
                    contentColor = MaterialTheme.colorScheme.onErrorContainer,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                Icon(Icons.AutoMirrored.Filled.Logout, contentDescription = null)
                Text("  Sign out")
            }
        }
    }
}

@Composable
private fun TrafficModePickerDialog(
    current: SettingsStore.MacTrafficMode,
    onDismiss: () -> Unit,
    onConfirm: (SettingsStore.MacTrafficMode) -> Unit,
) {
    var selected by remember { mutableStateOf(current) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Traffic capture") },
        text = {
            Column {
                listOf(
                    SettingsStore.MacTrafficMode.SYSTEM_PROXY,
                    SettingsStore.MacTrafficMode.GLOBAL_TUN,
                ).forEach { mode ->
                    val (label, detail) = when (mode) {
                        SettingsStore.MacTrafficMode.SYSTEM_PROXY ->
                            "System proxy" to "Browsers and apps that honor Windows proxy settings go through the VPN."
                        else ->
                            "Full tunnel" to "All system traffic (IPv4/IPv6) is captured by a virtual adapter, like a real VPN client. Asks for administrator approval once; after that it is silent."
                    }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(selected = selected == mode, onClick = { selected = mode })
                            .padding(vertical = 4.dp),
                    ) {
                        RadioButton(selected = selected == mode, onClick = { selected = mode })
                        Column(Modifier.padding(start = 8.dp)) {
                            Text(label)
                            Text(
                                detail,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(selected) }) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun DohProviderPickerDialog(
    current: SettingsStore.DohProvider,
    onDismiss: () -> Unit,
    onConfirm: (SettingsStore.DohProvider) -> Unit,
) {
    var selected by remember { mutableStateOf(current) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Encrypted DNS") },
        text = {
            Column {
                SettingsStore.DohProvider.entries.forEach { provider ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(selected = selected == provider, onClick = { selected = provider })
                            .padding(vertical = 4.dp),
                    ) {
                        RadioButton(selected = selected == provider, onClick = { selected = provider })
                        Column(Modifier.padding(start = 8.dp)) {
                            Text(provider.label)
                            val detail = when (provider) {
                                SettingsStore.DohProvider.AUTOMATIC -> "Use whichever answers first"
                                SettingsStore.DohProvider.OFF -> "Use the network's own DNS"
                                else -> provider.addresses.joinToString(", ")
                            }
                            Text(
                                detail,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(selected) }) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun CustomDnsPickerDialog(
    current: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var value by remember { mutableStateOf(current) }
    val isValid = SettingsStore.isValidDnsServer(value)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("DNS server") },
        text = {
            Column {
                SettingsStore.CUSTOM_DNS_PRESETS.forEach { (address, label) ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(selected = value == address, onClick = { value = address })
                            .padding(vertical = 4.dp),
                    ) {
                        RadioButton(selected = value == address, onClick = { value = address })
                        Text(label, modifier = Modifier.padding(start = 8.dp))
                    }
                }
                OutlinedTextField(
                    value = value,
                    onValueChange = { value = it.trim() },
                    label = { Text("IPv4 address") },
                    singleLine = true,
                    isError = value.isNotBlank() && !isValid,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(value) }, enabled = isValid) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun CustomEdgeAddressDialog(
    current: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var value by remember { mutableStateOf(current) }
    val trimmed = value.trim()
    val isValid = trimmed.isEmpty() || SettingsStore.isValidEdgeHost(trimmed)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Custom edge address") },
        text = {
            Column {
                OutlinedTextField(
                    value = value,
                    onValueChange = { value = it },
                    label = { Text("Host or IP") },
                    singleLine = true,
                    isError = !isValid,
                )
                Text(
                    "Leave empty to resolve the server hostname normally.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(trimmed) }, enabled = isValid) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun SocksBindAddressPickerDialog(
    current: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var selected by remember { mutableStateOf(current) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Local address") },
        text = {
            Column {
                SettingsStore.SOCKS_BIND_ADDRESS_PRESETS.forEach { (address, label) ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(selected = selected == address, onClick = { selected = address })
                            .padding(vertical = 4.dp),
                    ) {
                        RadioButton(selected = selected == address, onClick = { selected = address })
                        Text(label, modifier = Modifier.padding(start = 8.dp))
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(selected) }) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun SocksPortPickerDialog(
    current: Int,
    title: String = "Local port",
    onDismiss: () -> Unit,
    onConfirm: (Int) -> Unit,
) {
    var portText by remember { mutableStateOf(current.toString()) }
    val parsedPort = portText.toIntOrNull()
    val isValid = parsedPort != null && parsedPort in 1..65_535

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = portText,
                onValueChange = { portText = it.filter(Char::isDigit).take(5) },
                label = { Text("Port (1\u201365535)") },
                singleLine = true,
                isError = portText.isNotBlank() && !isValid,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            )
        },
        confirmButton = {
            TextButton(onClick = { parsedPort?.let { onConfirm(it) } }, enabled = isValid) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun IosShareDialog(
    lanAddress: String?,
    interfaceName: String?,
    port: Int,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val steps = lanAddress?.let { com.vauth.foxyvpn.vpn.http.IosProfile.manualSteps(it, port) }
        ?: "No local-network address was found. Connect this Mac to Wi-Fi or Ethernet first."
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Use the VPN on an iPhone") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                if (lanAddress != null) {
                    Text(
                        "Server: $lanAddress",
                        style = MaterialTheme.typography.titleSmall,
                    )
                    Text(
                        "Port: $port",
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.padding(bottom = 8.dp),
                    )
                    interfaceName?.let {
                        Text(
                            "($it; the Mac and the phone must be on the same network)",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    HorizontalDivider(Modifier.padding(vertical = 8.dp))
                }
                Text(steps, style = MaterialTheme.typography.bodyMedium)
                HorizontalDivider(Modifier.padding(vertical = 8.dp))
                Text(
                    "A .mobileconfig can also be exported for this proxy, but Apple only applies " +
                        "that payload on supervised devices; on a personal iPhone the manual steps " +
                        "above are the supported way. Either way the proxy only works while this " +
                        "Mac stays awake and Vulpine stays connected.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            Column(horizontalAlignment = Alignment.End) {
                TextButton(
                    onClick = {
                        com.vauth.foxyvpn.platform.Platform.copyText("$lanAddress:$port")
                        android.widget.Toast.makeText(context, "Address copied", android.widget.Toast.LENGTH_SHORT).show()
                    },
                    enabled = lanAddress != null,
                ) { Text("Copy address") }
                TextButton(
                    onClick = {
                        com.vauth.foxyvpn.platform.Platform.copyText(steps)
                        android.widget.Toast.makeText(context, "Steps copied", android.widget.Toast.LENGTH_SHORT).show()
                    },
                    enabled = lanAddress != null,
                ) { Text("Copy steps") }
                TextButton(
                    onClick = {
                        val server = lanAddress
                        if (server == null) {
                            android.widget.Toast.makeText(context, "No local address", android.widget.Toast.LENGTH_SHORT).show()
                        } else {
                            runCatching {
                                com.vauth.foxyvpn.vpn.http.IosProfile.writeFile(
                                    server,
                                    port,
                                    com.vauth.foxyvpn.vpn.http.hostName(),
                                )
                            }.onSuccess { file ->
                                com.vauth.foxyvpn.platform.Platform.revealInFinder(file)
                                android.widget.Toast.makeText(
                                    context,
                                    "Profile saved to Downloads",
                                    android.widget.Toast.LENGTH_SHORT,
                                ).show()
                            }.onFailure {
                                android.widget.Toast.makeText(
                                    context,
                                    "Could not write the profile: ${it.message}",
                                    android.widget.Toast.LENGTH_LONG,
                                ).show()
                            }
                        }
                    },
                ) { Text("Export .mobileconfig") }
                TextButton(onClick = onDismiss) { Text("Close") }
            }
        },
    )
}

@Composable
private fun UpstreamProxyTypePickerDialog(
    current: SettingsStore.UpstreamProxyType,
    onDismiss: () -> Unit,
    onConfirm: (SettingsStore.UpstreamProxyType) -> Unit,
) {
    var selected by remember { mutableStateOf(current) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Proxy type") },
        text = {
            Column {
                SettingsStore.UpstreamProxyType.entries.forEach { type ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(selected = selected == type, onClick = { selected = type })
                            .padding(vertical = 4.dp),
                    ) {
                        RadioButton(selected = selected == type, onClick = { selected = type })
                        Text(type.name, modifier = Modifier.padding(start = 8.dp))
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(selected) }) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun UpstreamProxyAddressDialog(
    currentHost: String,
    currentPort: Int,
    onDismiss: () -> Unit,
    onConfirm: (String, Int) -> Unit,
) {
    var host by remember { mutableStateOf(currentHost) }
    var portText by remember { mutableStateOf(currentPort.toString()) }
    val parsedPort = portText.toIntOrNull()
    val isValid = host.isNotBlank() && parsedPort != null && parsedPort in 1..65_535

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Proxy address") },
        text = {
            Column {
                OutlinedTextField(
                    value = host,
                    onValueChange = { host = it.trim() },
                    label = { Text("Host or IP") },
                    singleLine = true,
                )
                OutlinedTextField(
                    value = portText,
                    onValueChange = { portText = it.filter(Char::isDigit).take(5) },
                    label = { Text("Port (1\u201365535)") },
                    singleLine = true,
                    isError = portText.isNotBlank() && (parsedPort == null || parsedPort !in 1..65_535),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { parsedPort?.let { onConfirm(host, it) } }, enabled = isValid) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun UpstreamProxyCredentialsDialog(
    currentUsername: String,
    currentPassword: String,
    onDismiss: () -> Unit,
    onConfirm: (String, String) -> Unit,
) {
    var username by remember { mutableStateOf(currentUsername) }
    var password by remember { mutableStateOf(currentPassword) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Proxy credentials") },
        text = {
            Column {
                OutlinedTextField(
                    value = username,
                    onValueChange = { username = it },
                    label = { Text("Username (optional)") },
                    singleLine = true,
                )
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text("Password (optional)") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(username, password) }) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

private data class InstalledAppEntry(val packageName: String, val label: String)

@Composable
private fun SplitTunnelDialog(
    current: Set<String>,
    onDismiss: () -> Unit,
    onConfirm: (Set<String>) -> Unit,
) {
    val context = LocalContext.current
    var selected by remember { mutableStateOf(current) }
    var searchQuery by remember { mutableStateOf("") }

    val installedApps by androidx.compose.runtime.produceState<List<InstalledAppEntry>>(initialValue = emptyList()) {
        value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val packageManager = context.packageManager
            packageManager.getInstalledApplications(PackageManager.GET_META_DATA)
                .asSequence()
                .filter { it.packageName != context.packageName }
                .filter { packageManager.getLaunchIntentForPackage(it.packageName) != null }
                .map { info: android.content.pm.ApplicationInfo ->
                    InstalledAppEntry(info.packageName, info.loadLabel(packageManager).toString())
                }
                .sortedBy { it.label.lowercase() }
                .toList()
        }
    }
    val filteredApps = remember(installedApps, searchQuery) {
        if (searchQuery.isBlank()) {
            installedApps
        } else {
            installedApps.filter { it.label.contains(searchQuery, ignoreCase = true) }
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Split tunneling") },
        text = {
            Column {
                Text(
                    "Selected apps bypass the VPN and use your normal connection.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 8.dp),
                )
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    label = { Text("Search apps") },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    singleLine = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 8.dp),
                )
                if (installedApps.isEmpty()) {
                    androidx.compose.material3.CircularProgressIndicator(
                        modifier = Modifier.padding(24.dp).align(Alignment.CenterHorizontally)
                    )
                } else if (filteredApps.isEmpty()) {
                    Text(
                        "No apps match \"$searchQuery\".",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 12.dp),
                    )
                } else {
                    LazyColumn(modifier = Modifier.height(360.dp)) {
                        items(filteredApps, key = { it.packageName }) { app ->
                            val isChecked = selected.contains(app.packageName)
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        selected = if (isChecked) {
                                            selected - app.packageName
                                        } else {
                                            selected + app.packageName
                                        }
                                    }
                                    .padding(vertical = 2.dp),
                            ) {
                                Checkbox(
                                    checked = isChecked,
                                    onCheckedChange = {
                                        selected = if (it) selected + app.packageName else selected - app.packageName
                                    },
                                )
                                Text(app.label, modifier = Modifier.padding(start = 8.dp))
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(selected) }) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
}
