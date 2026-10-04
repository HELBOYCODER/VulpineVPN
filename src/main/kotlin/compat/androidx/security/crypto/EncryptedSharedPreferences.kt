package androidx.security.crypto

import android.content.SharedPreferences
import android.content.encryptedSharedPrefs

class MasterKey private constructor(val storeName: String?) {

    enum class KeyScheme { AES256_GCM }

    class Builder(private val context: android.content.Context) {
        fun setKeyScheme(scheme: KeyScheme): Builder = this

        fun build(): MasterKey = MasterKey(null)
    }

    companion object
}

object EncryptedSharedPreferences {

    enum class PrefKeyEncryptionScheme { AES256_SIV }

    enum class PrefValueEncryptionScheme { AES256_GCM }

    fun create(
        context: android.content.Context,
        fileName: String,
        masterKey: MasterKey,
        keyScheme: PrefKeyEncryptionScheme,
        valueScheme: PrefValueEncryptionScheme,
    ): SharedPreferences = encryptedSharedPrefs(fileName)
}
