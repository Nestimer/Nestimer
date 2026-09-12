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
import com.nestimer.agent.BuildConfig
import com.nestimer.agent.counting.UsageCounter
import com.nestimer.agent.data.Pairing
import com.nestimer.agent.net.AgentClient
import com.nestimer.agent.ui.SetupActivity
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import kotlin.concurrent.thread

/**
 * Recomputes today's foreground total every 60 seconds and reports it.
 *
 * No adaptive interval. The Mac agent varies its sync rate because it has to react fast
 * enough to lock the screen; this client never locks, so a flat 60s is both correct and
 * cheaper on battery.
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

    private fun reportOnce() {
        val pairing = Pairing.load(this)
        if (pairing == null) {
            updateNotification("Not paired — open NesTimer to set up")
            return
        }
        // Network on a background thread; the tick itself runs on the main looper.
        thread(isDaemon = true) {
            val now = System.currentTimeMillis()
            val startOfDay = startOfLocalDay(now)
            val localDate = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(now)

            val minutes = runCatching {
                UsageCounter.foregroundMinutes(
                    EventReader(this).eventsBetween(startOfDay, now),
                    startOfDay,
                    now,
                )
            }.getOrElse {
                Log.w(TAG, "Could not read usage events — is usage access granted?", it)
                updateNotification("Usage access not granted")
                return@thread
            }

            val client = AgentClient(pairing.server, pairing.token)
            client.postUsage(localDate, minutes)
            val config = client.fetchConfig(localDate, BuildConfig.VERSION_NAME)

            updateNotification(
                when {
                    config == null -> "Offline — last count ${minutes.toInt()} min"
                    config.remainingMinutes == null -> "No limit today · ${minutes.toInt()} min used"
                    else -> "${config.remainingMinutes!!.toInt()} min left today"
                }
            )
        }
    }

    private fun startOfLocalDay(nowMillis: Long): Long =
        Calendar.getInstance().apply {
            timeInMillis = nowMillis
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis

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
