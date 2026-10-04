package android.content

import com.vauth.foxyvpn.platform.FoxyPaths
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.Properties
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

private const val TAG = "PrefsStore"

interface SharedPreferences {
    fun getString(key: String, defValue: String?): String?
    fun getInt(key: String, defValue: Int): Int
    fun getLong(key: String, defValue: Long): Long
    fun getBoolean(key: String, defValue: Boolean): Boolean
    fun getStringSet(key: String, defValues: Set<String>?): Set<String>?
    fun contains(key: String): Boolean
    fun edit(): Editor

    interface Editor {
        fun putString(key: String, value: String?): Editor
        fun putInt(key: String, value: Int): Editor
        fun putLong(key: String, value: Long): Editor
        fun putBoolean(key: String, value: Boolean): Editor
        fun putStringSet(key: String, values: Set<String>?): Editor
        fun remove(key: String): Editor
        fun clear(): Editor
        fun apply()
        fun commit(): Boolean
    }
}

internal abstract class BasePreferences(private val file: File) : SharedPreferences {

    protected val props = Properties()

    @Synchronized
    protected fun load() {
        props.clear()
        if (file.exists()) {
            runCatching { FileInputStream(file).use { props.load(it) } }
        }
    }

    protected abstract fun encodeKey(key: String): String
    protected abstract fun decodeValue(stored: String): String?
    protected abstract fun encodeValue(value: String): String

    @Synchronized
    override fun getString(key: String, defValue: String?): String? {
        load()
        val raw = props.getProperty(encodeKey(key)) ?: return defValue
        val decoded = decodeValue(raw) ?: return defValue
        if (!decoded.startsWith("s")) return defValue
        return decoded.drop(1)
    }

    @Synchronized
    override fun getInt(key: String, defValue: Int): Int {
        load()
        val raw = props.getProperty(encodeKey(key)) ?: return defValue
        val decoded = decodeValue(raw) ?: return defValue
        if (!decoded.startsWith("i")) return defValue
        return decoded.drop(1).toIntOrNull() ?: defValue
    }

    @Synchronized
    override fun getLong(key: String, defValue: Long): Long {
        load()
        val raw = props.getProperty(encodeKey(key)) ?: return defValue
        val decoded = decodeValue(raw) ?: return defValue
        if (!decoded.startsWith("l")) return defValue
        return decoded.drop(1).toLongOrNull() ?: defValue
    }

    @Synchronized
    override fun getBoolean(key: String, defValue: Boolean): Boolean {
        load()
        val raw = props.getProperty(encodeKey(key)) ?: return defValue
        val decoded = decodeValue(raw) ?: return defValue
        if (!decoded.startsWith("b")) return defValue
        return decoded.drop(1) == "1"
    }

    @Synchronized
    override fun getStringSet(key: String, defValues: Set<String>?): Set<String>? {
        load()
        val raw = props.getProperty(encodeKey(key)) ?: return defValues
        val decoded = decodeValue(raw) ?: return defValues
        if (!decoded.startsWith("u")) return defValues
        return decoded.drop(1).split('\u0001').filter { it.isNotEmpty() }.toSet()
    }

    @Synchronized
    override fun contains(key: String): Boolean {
        load()
        return props.containsKey(encodeKey(key))
    }

    override fun edit(): SharedPreferences.Editor = EditorImpl()

    private fun saveLocked() {
        file.parentFile?.mkdirs()
        FileOutputStream(file).use { out ->
            props.store(out, null)
        }
        runCatching { file.setReadable(false, false).also { file.setReadable(true, false) } }
        runCatching { file.setWritable(false, false).also { file.setWritable(true, false) } }
    }

    private inner class EditorImpl : SharedPreferences.Editor {
        private val pending = LinkedHashMap<String, String?>()
        private var cleared = false

        override fun putString(key: String, value: String?): SharedPreferences.Editor =
            putTyped(key, if (value == null) null else "s$value")

        override fun putInt(key: String, value: Int): SharedPreferences.Editor = putTyped(key, "i$value")

        override fun putLong(key: String, value: Long): SharedPreferences.Editor = putTyped(key, "l$value")

        override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor =
            putTyped(key, "b" + if (value) "1" else "0")

        override fun putStringSet(key: String, values: Set<String>?): SharedPreferences.Editor =
            putTyped(key, if (values == null) null else "u" + values.joinToString("\u0001"))

        private fun putTyped(key: String, encoded: String?): SharedPreferences.Editor {
            pending[key] = encoded
            return this
        }

        override fun remove(key: String): SharedPreferences.Editor = putTyped(key, null)

        override fun clear(): SharedPreferences.Editor {
            cleared = true
            return this
        }

        @Synchronized
        override fun apply() {
            commit()
        }

        @Synchronized
        override fun commit(): Boolean = runCatching {
            load()
            if (cleared) {
                props.clear()
            }
            for ((key, encoded) in pending) {
                val storedKey = encodeKey(key)
                if (encoded == null) {
                    props.remove(storedKey)
                } else {
                    props.setProperty(storedKey, encodeValue(encoded))
                }
            }
            saveLocked()
            true
        }.getOrDefault(false)
    }
}

private fun emptyUnit() = Unit


internal class PlainPreferences(file: File) : BasePreferences(file) {
    override fun encodeKey(key: String): String = key
    override fun decodeValue(stored: String): String? = stored
    override fun encodeValue(value: String): String = value
}

/**
 * Desktop stand-in for EncryptedSharedPreferences: values are AES-256-GCM sealed with a
 * per-store random key kept in the app support directory (file mode 600).
 */
internal class EncryptedPreferences(file: File, keyFileName: String) : BasePreferences(file) {

    private val key: ByteArray by lazy { loadOrCreateKey(keyFileName) }

    override fun encodeKey(key: String): String =
        MessageDigest.getInstance("SHA-256").digest(("foxy:" + key).toByteArray()).joinToString("") { "%02x".format(it) }

    override fun decodeValue(stored: String): String? = runCatching {
        val parts = stored.split(':')
        if (parts.size != 2) return@runCatching null
        val iv = Base64.getDecoder().decode(parts[0])
        val ct = Base64.getDecoder().decode(parts[1])
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        String(cipher.doFinal(ct), Charsets.UTF_8)
    }.onFailure {
        android.util.Log.w(TAG, "failed to decrypt a stored preference", it)
    }.getOrNull()

    override fun encodeValue(value: String): String {
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        val ct = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return Base64.getEncoder().encodeToString(iv) + ":" + Base64.getEncoder().encodeToString(ct)
    }

    private fun loadOrCreateKey(name: String): ByteArray {
        val keyFile = File(FoxyPaths.keysDir, name + ".key")
        if (keyFile.exists() && keyFile.length() == 32L) {
            return keyFile.readBytes()
        }
        val generated = ByteArray(32).also { SecureRandom().nextBytes(it) }
        keyFile.parentFile?.mkdirs()
        keyFile.writeBytes(generated)
        runCatching {
            keyFile.setReadable(false, false)
            keyFile.setReadable(true, false)
            keyFile.setWritable(false, false)
            keyFile.setWritable(true, false)
        }
        return generated
    }
}

fun sharedPrefs(name: String): SharedPreferences =
    PlainPreferences(File(FoxyPaths.prefsDir, "$name.properties"))

fun encryptedSharedPrefs(name: String): SharedPreferences =
    EncryptedPreferences(File(FoxyPaths.prefsDir, "$name.properties"), name)
