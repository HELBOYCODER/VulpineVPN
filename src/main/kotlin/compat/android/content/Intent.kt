package android.content

import android.net.Uri
import com.vauth.foxyvpn.platform.FoxyPaths
import com.vauth.foxyvpn.platform.Platform

open class Intent {
    var action: String? = null
        private set
    var data: Uri? = null
    var type: String? = null

    private val extras = LinkedHashMap<String, Any?>()
    private var chooserTitle: String? = null
    private var chooserTarget: Intent? = null

    constructor(action: String) {
        this.action = action
    }

    constructor(action: String, data: Uri?) {
        this.action = action
        this.data = data
    }

    fun putExtra(name: String, value: String?): Intent {
        extras[name] = value
        return this
    }

    fun putExtra(name: String, value: Uri?): Intent {
        extras[name] = value
        return this
    }

    @Suppress("UNCHECKED_CAST", "unused")
    fun <T> getParcelableExtra(name: String): T? = extras[name] as? T

    @Suppress("unused")
    fun getStringExtra(name: String): String? = extras[name] as? String

    @Suppress("unused", "UNUSED_PARAMETER")
    fun addFlags(flags: Int): Intent = this

    @Suppress("unused")
    fun setType(mime: String?): Intent {
        type = mime
        return this
    }

    internal fun run() {
        chooserTarget?.let {
            it.chooserTitle = chooserTitle
            return it.run()
        }
        when (action) {
            ACTION_VIEW -> data?.let { Platform.openUrl(it.toString()) }
            ACTION_SEND -> {
                val uri = extras[EXTRA_STREAM] as? Uri
                val source = uri?.file
                val name = extras[EXTRA_SUBJECT] as? String ?: uri?.fileName ?: "foxyvpn-export.txt"
                if (source != null) {
                    val dest = FoxyPaths.exportFile(name)
                    source.copyTo(dest, overwrite = true)
                    Platform.revealInFinder(dest)
                }
            }
        }
    }

    companion object {
        const val ACTION_VIEW = "android.intent.action.VIEW"
        const val ACTION_SEND = "android.intent.action.SEND"
        const val EXTRA_STREAM = "android.intent.extra.STREAM"
        const val EXTRA_SUBJECT = "android.intent.extra.SUBJECT"
        const val FLAG_GRANT_READ_URI_PERMISSION = 1
        const val FLAG_ACTIVITY_NEW_TASK = 0x10000000

        fun createChooser(target: Intent, title: String?): Intent =
            Intent(ACTION_VIEW).apply {
                chooserTarget = target
                chooserTitle = title
            }
    }
}
