package android.content.pm

import java.io.File

open class ApplicationInfo(val packageName: String, val label: String) {
    fun loadLabel(pm: PackageManager): CharSequence = label
}

abstract class PackageManager {
    abstract fun getInstalledApplications(flags: Int): List<ApplicationInfo>
    abstract fun getLaunchIntentForPackage(packageName: String): android.content.Intent?

    companion object {
        const val GET_META_DATA = 0
    }
}

/**
 * Enumerates macOS application bundles so the split-tunneling picker keeps working.
 * The "package name" is the bundle path on disk.
 */
object MacPackageManager : PackageManager() {

    private val appDirs: List<File> = listOf(
        File("/Applications"),
        File(System.getProperty("user.home"), "Applications"),
        File("/System/Applications"),
        File("/System/Applications/Utilities"),
    )

    override fun getInstalledApplications(flags: Int): List<ApplicationInfo> =
        appDirs.filter { it.isDirectory }
            .flatMap { dir -> dir.listFiles()?.toList().orEmpty() }
            .filter { it.isDirectory && it.name.endsWith(".app") }
            .map { app -> ApplicationInfo(app.absolutePath, app.name.removeSuffix(".app")) }

    override fun getLaunchIntentForPackage(packageName: String): android.content.Intent? {
        val app = File(packageName)
        if (!app.isDirectory || !app.name.endsWith(".app")) return null
        return android.content.Intent(
            android.content.Intent.ACTION_VIEW,
            android.net.Uri.fromFile(app),
        )
    }
}
