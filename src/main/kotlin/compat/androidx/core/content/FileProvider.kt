package androidx.core.content

import android.net.Uri
import java.io.File

object FileProvider {
    fun getUriForFile(context: android.content.Context, authority: String, file: File): Uri =
        Uri.fromFile(file)
}
