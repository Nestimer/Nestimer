package com.nestimer.agent.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi
import com.nestimer.agent.BuildConfig
import com.nestimer.agent.counting.UsageCounter
import com.nestimer.agent.data.Pairing
import com.nestimer.agent.data.UsageFloor
import com.nestimer.agent.net.AgentClient
import com.nestimer.agent.ui.SetupActivity
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlin.concurrent.thread

/**
 * Recomputes today's foreground total every 60 seconds and reports it.
 *
 * No adaptive interval. The Mac agent varies its sync rate because it has to react fast
 * enough to lock the screen; this client never locks, so a flat 60s is both correct and
 * cheaper on battery.
 *
 * Foreground service type is `specialUse`, not the more obviously-named `dataSync`, for
 * two concrete reasons that a future reader will otherwise "fix" back:
 * 1. The child's phone runs Android 15+, where `dataSync` at `targetSdk 35` is capped
 *    near 6 hours per 24h — the system calls `onTimeout()` and a service that has not
 *    stopped itself by then is at risk of an ANR. This service is meant to run all day.
 * 2. Android 14+ refuses to let a `dataSync` foreground service be started from a
 *    `BOOT_COMPLETED` receiver, which would silently break `BootReceiver`'s whole job.
 * `specialUse` has neither restriction, at the cost of needing the
 * `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` manifest property to say why it exists.
 */
class CountingService : Service() {

    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            reportOnce()
            handler.postDelayed(this, TICK_MILLIS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification("Starting…"))
        handler.post(tick)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        super.onDestroy()
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    override fun onTimeout(startId: Int) {
        // specialUse is not documented to carry a timeout the way dataSync's ~6h cap
        // does, but this is defensive: if a future platform level applies one anyway,
        // stop cleanly here rather than risk the system ANR-ing an unresponsive service.
        Log.w(TAG, "onTimeout() called — stopping the service instead of risking an ANR")
        stopSelf(startId)
    }

    private fun reportOnce() {
        // Pairing.load touches EncryptedSharedPreferences (Keystore + file I/O), so —
        // like the counting and network work below — it happens on this background
        // thread rather than on the main looper that drives the 60s tick.
        thread(isDaemon = true) {
            val pairing = Pairing.load(this)
            if (pairing == null) {
                updateNotification("Not paired — open NesTimer to set up")
                return@thread
            }

            if (!UsageAccess.isGranted(this)) {
                // Do not report anything this tick. UsageStatsManager.queryEvents does
                // not throw without this grant — it silently returns zero events, which
                // would read as a confident 0.0. Since /agent/usage takes a posted value
                // as this device's absolute total for the day (not a delta), and that
                // total is summed across every device on the child's account, posting a
                // zero here would erase real usage and unlock every device, not just
                // fail to count on this one. See UsageAccess's KDoc.
                updateNotification("Usage access not granted — open NesTimer to fix")
                return@thread
            }

            // One reading of the clock, in one zone, for all three values — so the
            // window, the date the usage is filed under, and the floor's key can never
            // disagree because the clock ticked over between two separate reads.
            // LocalDate.toString() is ISO yyyy-MM-dd by definition, with no locale or
            // per-tick formatter allocation involved.
            val zone = ZoneId.systemDefault()
            val nowLocal = ZonedDateTime.now(zone)
            val now = nowLocal.toInstant().toEpochMilli()
            val startOfDay = nowLocal.toLocalDate().atStartOfDay(zone).toInstant().toEpochMilli()
            val localDate = nowLocal.toLocalDate().toString()

            val derived = runCatching {
                UsageCounter.foregroundMinutes(
                    EventReader(this).eventsBetween(startOfDay, now),
                    startOfDay,
                    now,
                )
            }.getOrElse {
                // Belt-and-braces: the UsageAccess check above is the real gate. This
                // catches anything else queryEvents could throw.
                Log.w(TAG, "Could not read usage events despite granted access", it)
                updateNotification("Usage access not granted")
                return@thread
            }

            // Never post less than this app has already posted today. The server reads
            // a decrease as a parent's deliberate reset and passes it through, which
            // would erase the day's usage on every one of the child's devices. See
            // UsageFloor — the floor is this client's own derived number and nothing
            // that came back from the server.
            val minutes = UsageFloor.floored(this, localDate, derived)

            runCatching {
                val client = AgentClient(pairing.server, pairing.token)
                val posted = client.postUsage(localDate, minutes)
                if (!posted) {
                    Log.w(TAG, "postUsage returned failure — usage not recorded server-side this tick")
                }
                val config = client.fetchConfig(localDate, BuildConfig.VERSION_NAME)

                updateNotification(
                    when {
                        config != null && config.remainingMinutes == null ->
                            "No limit today · ${minutes.toInt()} min used"
                        config != null ->
                            "${config.remainingMinutes!!.toInt()} min left today"
                        !posted ->
                            // The report itself failed: connectivity or the saved
                            // pairing/token is the likely cause, so point at re-pairing
                            // rather than "check your WiFi" the way "Offline" used to.
                            "Could not report usage — check pairing"
                        else ->
                            // The POST succeeded — so connectivity and the token are
                            // both fine — but the follow-up GET for status did not. A
                            // narrower, more transient failure than the line above.
                            "Reported ${minutes.toInt()} min, but could not fetch status"
                    }
                )
            }.onFailure {
                // Guards against a malformed server URL escaping AgentClient's own
                // internal runCatching — Request.Builder.url()/toHttpUrl() throw
                // IllegalArgumentException outside it for a string with no scheme.
                // Pairing.parse rejects that on new pairings, but an old saved pairing
                // predating that check must not crash-loop this service once a minute.
                Log.w(TAG, "Network round-trip failed", it)
                updateNotification("Could not reach server")
            }
        }
    }

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Screen time",
            NotificationManager.IMPORTANCE_LOW, // no sound; it is permanent
        ).apply { setShowBadge(false) }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, SetupActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("NesTimer")
            .setContentText(text)
            // NOTE: the brief specified `ic_lock_idle_clock`, which does not exist in the
            // compileSdk 35 framework (verified via aapt2 dump / javap on android.jar) —
            // substituted the nearest equivalent that does, and is public: a clock icon.
            // Mirrored in AndroidManifest.xml's android:icon for the same reason.
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(text))
    }

    companion object {
        private const val TAG = "NesTimerService"
        private const val CHANNEL_ID = "nestimer_screen_time"
        private const val NOTIFICATION_ID = 1
        private const val TICK_MILLIS = 60_000L

        fun start(context: Context) {
            val intent = Intent(context, CountingService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
