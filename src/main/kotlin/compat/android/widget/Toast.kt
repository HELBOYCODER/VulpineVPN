package android.widget

import kotlinx.coroutines.flow.MutableStateFlow

data class ToastMessage(val id: Long, val text: String)

object ToastBus {
    val latest = MutableStateFlow<ToastMessage?>(null)
}

class Toast private constructor(private val text: String) {

    fun show() {
        ToastBus.latest.value = ToastMessage(System.nanoTime(), text)
    }

    companion object {
        const val LENGTH_SHORT = 0
        const val LENGTH_LONG = 1

        @JvmStatic
        @JvmOverloads
        fun makeText(context: android.content.Context?, text: CharSequence, duration: Int): Toast =
            Toast(text.toString())
    }
}
