package android.util

@Suppress("unused")
object Base64 {
    const val DEFAULT = 0
    const val NO_PADDING = 1
    const val NO_WRAP = 2
    const val URL_SAFE = 8

    fun encodeToString(input: ByteArray, flags: Int): String {
        val encoder = if (flags and URL_SAFE != 0) java.util.Base64.getUrlEncoder() else java.util.Base64.getEncoder()
        val withPadding = if (flags and NO_PADDING != 0) encoder.withoutPadding() else encoder
        return withPadding.encodeToString(input)
    }

    fun encode(input: ByteArray, flags: Int): ByteArray = encodeToString(input, flags).toByteArray(Charsets.US_ASCII)

    fun decode(text: String, flags: Int): ByteArray = try {
        val decoder = if (flags and URL_SAFE != 0) java.util.Base64.getUrlDecoder() else java.util.Base64.getMimeDecoder()
        decoder.decode(text)
    } catch (e: IllegalArgumentException) {
        throw AssertionError("Bad base64", e)
    }
}
