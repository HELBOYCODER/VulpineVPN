package android.net

import java.io.File

class Uri private constructor(val value: String, val file: File?) {

    val fileName: String
        get() = file?.name ?: value.substringAfterLast('/').substringBefore('?')

    override fun toString(): String = value

    override fun equals(other: Any?): Boolean = other is Uri && other.value == value

    override fun hashCode(): Int = value.hashCode()

    companion object {
        fun parse(value: String): Uri = Uri(value, null)

        fun fromFile(file: File): Uri = Uri(file.toURI().toString(), file)
    }
}
