package io.nikodesk.android.credentials

import android.content.Context
import android.os.Process
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

// Plain authentication material never reaches Flutter or backup storage.
object NikoCredentialBridge {
    private const val alias = "io.nikodesk.controller.credentials.v1"
    private var context: Context? = null
    @JvmStatic private external fun nativeInitialize(): Boolean

    @JvmStatic @Synchronized fun initialize(value: Context): Boolean = try {
        val app = value.applicationContext
        require(Process.myUid() >= 10000 && (app.packageName == "io.nikodesk.android" || app.packageName == "io.nikodesk.android.dev"))
        require(context == null || context === app)
        context = app
        nativeInitialize()
    } catch (_: RuntimeException) { false } catch (_: LinkageError) { false }

    private fun file(account: String, create: Boolean = false): AtomicFile {
        require(account.matches(Regex("[a-f0-9]{64}")))
        val app = checkNotNull(context)
        val directory = File(app.noBackupFilesDir, "controller-credentials-v1")
        if (create) require(directory.isDirectory || directory.mkdirs())
        return AtomicFile(File(directory, "$account.enc"))
    }
    private fun key(create: Boolean): SecretKey? {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias(alias)) return store.getKey(alias, null) as SecretKey
        if (!create) return null
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    @JvmStatic @Synchronized fun read(account: String): ByteArray? {
        val file = file(account)
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
        val bytes = file.openRead().use {
            require(it.channel.size() <= 4096)
            it.readBytes()
        }
        require(bytes.size in 30..4096 && bytes[0] == 1.toByte())
        val key = checkNotNull(key(false))
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
            updateAAD(account.toByteArray(Charsets.US_ASCII))
            doFinal(bytes, 13, bytes.size - 13)
        }
    }
    @JvmStatic @Synchronized fun write(account: String, bytes: ByteArray): Boolean {
        require(bytes.size in 1..1024)
        val file = file(account, create = true)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, checkNotNull(key(true)))
            updateAAD(account.toByteArray(Charsets.US_ASCII))
        }
        require(cipher.iv.size == 12)
        val encrypted = byteArrayOf(1) + cipher.iv + cipher.doFinal(bytes)
        val stream = file.startWrite()
        try {
            stream.write(encrypted)
            file.finishWrite(stream)
            return true
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }
    }
    @JvmStatic @Synchronized fun delete(account: String): Boolean {
        val file = file(account)
        file.delete()
        return !file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()
    }
}
