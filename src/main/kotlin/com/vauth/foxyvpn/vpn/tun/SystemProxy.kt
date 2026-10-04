package com.vauth.foxyvpn.vpn.tun

import com.vauth.foxyvpn.data.AppLogger
import com.vauth.foxyvpn.platform.Os

private const val TAG = "SystemProxy"

/**
 * Cross-platform system-proxy backend:
 * - macOS: privileged LaunchDaemon helper (admin approval once).
 * - Windows: HKCU Internet Settings via `reg add` — per-user, no admin needed.
 */
object SystemProxy {

    fun start(port: Int): Boolean = when {
        Os.isWindows -> WinHelper.startSystemProxy(port)
        else -> MacHelper.startSystemProxy(port)
    }

    fun stop(): Boolean = when {
        Os.isWindows -> WinHelper.stopSystemProxy()
        else -> MacHelper.stopSystemProxy()
    }

    /** App-quit path: restore the machine, keep any installed helper. */
    fun release() {
        runCatching {
            if (Os.isWindows) WinHelper.releaseSystem() else MacHelper.releaseSystem()
        }.onFailure { AppLogger.w(TAG, "could not release the system proxy on exit", it) }
    }
}
