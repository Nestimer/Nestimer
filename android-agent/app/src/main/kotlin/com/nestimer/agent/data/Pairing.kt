package com.nestimer.agent.data

import android.content.Context
import android.util.Log
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
        private const val TAG = "NesTimerPairing"
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

        /**
         * The saved pairing, or null if there is none **or it cannot be read**.
         *
         * The keystore can fail: `security-crypto` is still an alpha with a real record
         * of `GeneralSecurityException` on OEM devices, the master key can be
         * invalidated by a lock-screen change or a restore, and the prefs file can be
         * corrupted. None of that may be allowed to throw. `CountingService` calls this
         * from inside a bare `thread { }`, where an uncaught exception takes the whole
         * process down once a minute, and `SetupActivity` calls it during `onResume` —
         * so an unguarded throw here is a crash on launch with no way out but clearing
         * app data. Degrading to "not paired" leaves the parent with a screen that says
         * so and a Pair button that overwrites the unreadable entry.
         */
        fun load(context: Context): Pairing? = runCatching {
            val p = prefs(context)
            val server = p.getString(KEY_SERVER, null) ?: return@runCatching null
            val token = p.getString(KEY_TOKEN, null) ?: return@runCatching null
            Pairing(server, token)
        }.getOrElse {
            Log.w(TAG, "Could not read the saved pairing — treating this device as unpaired", it)
            null
        }

        /**
         * Saves the pairing; returns false if it could not be written.
         *
         * Guarded for the same reason as [load], and it reports rather than silently
         * swallowing: a parent who taps Pair must not be told "Paired with …" by an app
         * that stored nothing and will sit at "Not reporting yet" forever.
         */
        fun save(context: Context, server: String, token: String): Boolean = runCatching {
            prefs(context).edit().putString(KEY_SERVER, server).putString(KEY_TOKEN, token).apply()
            true
        }.getOrElse {
            Log.w(TAG, "Could not save the pairing", it)
            false
        }

        /** Parse "https://my.nestimer.com|eyJ..." — split on the single "|", as the Mac does. */
        fun parse(setupString: String): Pairing? {
            val parts = setupString.trim().split("|")
            if (parts.size != 2) return null
            val server = parts[0].trim().trimEnd('/')
            val token = parts[1].trim()
            if (server.isEmpty() || token.isEmpty()) return null
            // A scheme-less host (e.g. a parent pasting "my.nestimer.com" without the
            // "https://") saves cleanly but then crashes AgentClient's URL building
            // (Request.Builder.url()/toHttpUrl() throw IllegalArgumentException outside
            // its own runCatching) once a minute, forever. Reject it here instead.
            if (!server.startsWith("http://", ignoreCase = true) &&
                !server.startsWith("https://", ignoreCase = true)
            ) return null
            return Pairing(server, token)
        }
    }
}
