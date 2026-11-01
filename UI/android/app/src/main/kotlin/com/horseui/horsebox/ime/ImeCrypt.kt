package com.horseui.horsebox.ime

import android.content.Context
import android.util.Base64
import java.io.File
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 和 Flutter 的 SecretVault 完全一致的封装：
 * AES-256-GCM，格式 enc1: + base64(iv || 密文 || tag)，密钥是数据目录里的 secret.key。
 *
 * 拿不到密钥（首次启动还没生成）就原样存明文，和 Dart 侧行为一致。
 */
object ImeCrypt {
    private const val PREFIX = "enc1:"
    private const val IV_LENGTH = 12
    private const val TAG_BITS = 128

    private var cached: SecretKey? = null

    private fun key(context: Context): SecretKey? {
        cached?.let { return it }
        return try {
            val file = File(context.filesDir, "secret.key")
            if (!file.exists()) return null
            val bytes = Base64.decode(file.readText().trim(), Base64.DEFAULT)
            if (bytes.size != 32) return null
            SecretKeySpec(bytes, "AES").also { cached = it }
        } catch (_: Throwable) {
            null
        }
    }

    fun seal(context: Context, plain: String): String {
        val secret = key(context) ?: return plain
        return try {
            val iv = ByteArray(IV_LENGTH)
            SecureRandom().nextBytes(iv)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secret, GCMParameterSpec(TAG_BITS, iv))
            val body = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
            PREFIX + Base64.encodeToString(iv + body, Base64.NO_WRAP)
        } catch (_: Throwable) {
            plain
        }
    }

    fun open(context: Context, stored: String): String {
        if (!stored.startsWith(PREFIX)) return stored
        val secret = key(context) ?: return ""
        return try {
            val bytes = Base64.decode(stored.substring(PREFIX.length), Base64.DEFAULT)
            if (bytes.size <= IV_LENGTH) return ""
            val iv = bytes.copyOfRange(0, IV_LENGTH)
            val body = bytes.copyOfRange(IV_LENGTH, bytes.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(TAG_BITS, iv))
            String(cipher.doFinal(body), Charsets.UTF_8)
        } catch (_: Throwable) {
            ""
        }
    }
}
