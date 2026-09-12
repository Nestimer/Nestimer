package com.nestimer.agent.data

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * The `server|token` pair, in the same format the Mac agent's setup dialog parses
 * (`ParentApp/NesTimer/Views/AddDeviceView.swift:36`).
 *
 * The token is a device JWT that grants usage reporting for one device, so it lives in
 * EncryptedSharedPreferences rather than plain prefs.
 */
data class Pairing(val server: String, val token: String) {

    companion object {
        private const val FILE = "nestimer_pairing"
        private const val KEY_SERVER = "server"
        private const val KEY_TOKEN = "token"

        private fun prefs(context: Context) = EncryptedSharedPreferences.create(
            context,
            FILE,
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )

        fun load(context: Context): Pairing? {
            val p = prefs(context)
            val server = p.getString(KEY_SERVER, null) ?: return null
            val token = p.getString(KEY_TOKEN, null) ?: return null
            return Pairing(server, token)
        }

        fun save(context: Context, server: String, token: String) {
            prefs(context).edit().putString(KEY_SERVER, server).putString(KEY_TOKEN, token).apply()
        }

        /** Parse "https://my.nestimer.com|eyJ..." — split on the single "|", as the Mac does. */
        fun parse(setupString: String): Pairing? {
            val parts = setupString.trim().split("|")
            if (parts.size != 2) return null
            val server = parts[0].trim().trimEnd('/')
            val token = parts[1].trim()
            if (server.isEmpty() || token.isEmpty()) return null
            return Pairing(server, token)
        }
    }
}
