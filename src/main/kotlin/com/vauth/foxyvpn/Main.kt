package com.vauth.foxyvpn

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import androidx.navigation.compose.rememberNavController
import com.vauth.foxyvpn.ui.navigation.FoxyNavGraph
import com.vauth.foxyvpn.ui.theme.FoxyVpnTheme
import com.vauth.foxyvpn.ui.theme.rememberThemeController
import com.vauth.foxyvpn.vpn.FoxyVpnService
import com.vauth.foxyvpn.vpn.tun.SystemProxy
import android.widget.ToastBus
import android.widget.ToastMessage
import kotlinx.coroutines.delay

fun main() {
    val app = FoxyVpnApp().apply { onCreate() }

    application {
        val windowState = rememberWindowState(width = 460.dp, height = 880.dp)
        Window(
            onCloseRequest = {
                if (FoxyVpnService.state.value != com.vauth.foxyvpn.data.model.ConnectionState.DISCONNECTED) {
                    FoxyVpnService.stop(app)
                    Thread.sleep(1_500)
                }
                SystemProxy.release()
                exitApplication()            },
            title = "Vulpine VPN",
            state = windowState,
        ) {
            val themeController = rememberThemeController(app.settingsStore)
            FoxyVpnTheme(themeMode = themeController.mode) {
                Surface(modifier = Modifier.fillMaxSize()) {
                    Box(modifier = Modifier.fillMaxSize()) {
                        val navController = rememberNavController()
                        FoxyNavGraph(
                            navController = navController,
                            app = app,
                            themeController = themeController,
                            onRequestConnect = { FoxyVpnService.start(app) },
                            onDisconnect = { FoxyVpnService.stop(app) },
                        )
                        DesktopToastHost()
                    }
                }
            }
        }
    }
}

@Composable
private fun DesktopToastHost() {
    val latest by ToastBus.latest.collectAsState()
    LaunchedEffect(latest) {
        if (latest != null) {
            delay(3_500)
            if (ToastBus.latest.value == latest) ToastBus.latest.value = null
        }
    }
    AnimatedVisibility(
        visible = latest != null,
        enter = fadeIn(),
        exit = fadeOut(),
        modifier = Modifier.fillMaxSize(),
    ) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
            Snackbar(
                modifier = Modifier.padding(16.dp),
                containerColor = MaterialTheme.colorScheme.inverseSurface,
                contentColor = MaterialTheme.colorScheme.inverseOnSurface,
            ) {
                androidx.compose.material3.Text(latest?.text.orEmpty())
            }
        }
    }
}
