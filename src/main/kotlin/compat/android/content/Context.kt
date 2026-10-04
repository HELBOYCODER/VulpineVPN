package android.content

import com.vauth.foxyvpn.platform.FoxyPaths
import java.io.File

open class Context {

    open val applicationContext: Context get() = this

    open val filesDir: File get() = FoxyPaths.filesDir

    open val cacheDir: File get() = FoxyPaths.cacheDir

    open val packageName: String get() = FoxyPaths.PACKAGE_ID

    open val packageManager: android.content.pm.PackageManager get() = android.content.pm.MacPackageManager

    private val prefsCache = HashMap<String, SharedPreferences>()

    fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
        synchronized(prefsCache) { prefsCache.getOrPut(name) { sharedPrefs(name) } }

    open fun startActivity(intent: Intent) = intent.run()

    open fun getSystemService(name: String): Any? = when (name) {
        CLIPBOARD_SERVICE -> android.content.AndroidClipboardManager
        else -> null
    }

    companion object {
        const val MODE_PRIVATE = 0
        const val CLIPBOARD_SERVICE = "clipboard"
    }
}

class ClipData private constructor(val text: String) {
    companion object {
        fun newPlainText(label: String?, text: String): ClipData = ClipData(text)
    }
}

abstract class ClipboardManager {
    abstract fun setPrimaryClip(clip: ClipData)
}

object AndroidClipboardManager : ClipboardManager() {
    override fun setPrimaryClip(clip: ClipData) {
        com.vauth.foxyvpn.platform.Platform.copyText(clip.text)
    }
}
