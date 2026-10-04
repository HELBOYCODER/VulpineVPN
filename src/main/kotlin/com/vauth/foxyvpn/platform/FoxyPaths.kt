package com.vauth.foxyvpn.platform

import java.io.File

object AppHolder {
    @Volatile
    lateinit var context: android.content.Context
}

object FoxyPaths {
    const val PACKAGE_ID = "com.vauth.foxyvpn"

    val dataDir: File by lazy {
        val override = System.getProperty("foxy.data.dir")
        val dir = if (!override.isNullOrBlank()) {
            File(override)
        } else if (Os.isWindows) {
            val appData = System.getenv("APPDATA") ?: "${System.getProperty("user.home")}\\AppData\\Roaming"
            File(appData, "FoxyVPN")
        } else {
            File(System.getProperty("user.home"), "Library/Application Support/FoxyVPN")
        }
        dir.mkdirs()
        dir
    }

    val filesDir: File by lazy { File(dataDir, "files").apply { mkdirs() } }
    val cacheDir: File by lazy { File(dataDir, "cache").apply { mkdirs() } }
    val prefsDir: File by lazy { File(dataDir, "prefs").apply { mkdirs() } }
    val keysDir: File by lazy { File(dataDir, "keys").apply { mkdirs() } }
    val exportsDir: File by lazy { File(dataDir, "exports").apply { mkdirs() } }
    val helperDir: File by lazy { File(dataDir, "helper").apply { mkdirs() } }

    fun exportFile(name: String): File = File(exportsDir, name)

    /**
     * Resolves a bundled native helper (sing-box) shipped in the app image's Resources
     * (app-resources/sandbox via jpackage), or a dev-time location.
     */
    fun bundledResource(name: String): File? {
        val candidates = mutableListOf<File>()
        System.getProperty("foxy.resource.dir")?.let { candidates.add(File(it, name)) }
        // When run from the packaged .app: .../FoxyVPN.app/Contents/app/../Resources? jpackage
        // places app-resources under Contents/Resources/<subdir> only via a custom layout.
        // We instead search next to the main jar (jpackage --input layout).
        val codeBase = runCatching {
            File(FoxyPaths::class.java.protectionDomain.codeSource.location.toURI())
        }.getOrNull()
        if (codeBase != null) {
            val base = if (codeBase.isDirectory) codeBase else codeBase.parentFile
            base?.let {
                candidates.add(File(it, "resources/$name"))
                candidates.add(File(it.parentFile ?: it, "resources/$name"))
                // jpackage app layout: <App>.app/Contents/app/<jar> and <App>.app/Contents/Resources/
                candidates.add(File(it.parentFile ?: it, "Resources/sandbox/$name"))
                candidates.add(File(it.parentFile ?: it, "Resources/$name"))
            }
        }
        candidates.add(File(dataDir, "vendor/$name"))
        val devCheckout = File(
            System.getProperty("user.dir"),
            "vendor/$name",
        )
        candidates.add(devCheckout)
        return candidates.firstOrNull {
            if (!it.isFile) return@firstOrNull false
            runCatching { it.setExecutable(true, false) }
            true
        }
    }
}
