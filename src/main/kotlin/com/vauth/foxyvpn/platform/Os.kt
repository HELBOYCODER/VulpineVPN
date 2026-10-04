package com.vauth.foxyvpn.platform

enum class HostOs { MACOS, WINDOWS, OTHER }

object Os {
    val current: HostOs by lazy {
        val name = System.getProperty("os.name").orEmpty().lowercase()
        when {
            name.contains("mac") || name.contains("darwin") -> HostOs.MACOS
            name.contains("windows") -> HostOs.WINDOWS
            else -> HostOs.OTHER
        }
    }

    val isWindows: Boolean get() = current == HostOs.WINDOWS
    val isMac: Boolean get() = current == HostOs.MACOS
}
