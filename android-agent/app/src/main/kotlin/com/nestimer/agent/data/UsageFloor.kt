package com.nestimer.agent.data

import android.content.Context
import android.util.Log

/**
 * The highest total this app has put forward for a given local date.
 *
 * Recorded when the number is computed, not when the POST comes back: a floor that
 * counts a tick whose upload failed is harmless (the next tick derives at least as much
 * anyway), while making it depend on the network would mean a dropped response could
 * lower the next post.
 *
 * `/agent/usage` takes an **absolute** total for the day, and the server's clamp only
 * ceilings growth — a *decrease* is passed straight through, because a decrease is how a
 * parent's deliberate reset reaches the device row. So a client that ever posts a number
 * lower than one it already posted silently erases real usage, and since `/agent/config`
 * sums `used_minutes_today` across every device on the child's account, it hands those
 * minutes back on the Mac as well. `last_seen` keeps advancing the whole time, so no
 * silence detection can notice.
 *
 * The derived total is not naturally monotonic: it is measured from local midnight to
 * `now`, both read from the wall clock. Move the device's time zone backward while the
 * calendar date stays the same and that window shrinks. (Ordinary DST is *not* a
 * trigger — local midnight resolves with the correct historical offset and the epoch
 * clock does not jump — this is deliberate tampering, or a manual clock correction.)
 * Flooring each post at the highest one already made removes the whole class.
 *
 * ## The floor is this client's own number, never the server's
 *
 * What is stored here is only ever a value **this app derived from `UsageStatsManager`**.
 * Nothing from `/agent/config` — not `used_minutes_today`, not `device_used_minutes`,
 * nothing — may be fed into it. `used_minutes_today` is the sum across *all* the child's
 * devices; reading it back would make the phone re-report the Mac's minutes as its own
 * and compound them on every tick across both devices. That is exactly the bug that
 * shipped in macOS agent 2.9. The counter stays stateless about usage; this is a
 * one-way ratchet on what has already been sent, not a stored tally.
 *
 * Keyed by local date, so a new day resets the floor by simply not matching.
 *
 * Plain [android.content.SharedPreferences], not the encrypted store: the number is not
 * a secret, and — like [Pairing.load] — this must not be able to throw. It runs inside
 * the service's once-a-minute background thread, where an uncaught exception kills the
 * process.
 */
object UsageFloor {

    private const val TAG = "NesTimerFloor"
    private const val FILE = "nestimer_usage_floor"
    private const val KEY_DATE = "date"
    private const val KEY_MINUTES = "minutes"

    /**
     * Returns [minutes], or the stored floor for [localDate] if that is higher, and
     * remembers the result as the new floor.
     *
     * On any storage failure it returns [minutes] unchanged: a missing floor can only
     * cost accuracy in a tampering case, while throwing here would kill the service.
     */
    fun floored(context: Context, localDate: String, minutes: Double): Double =
        runCatching {
            val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
            val storedDate = prefs.getString(KEY_DATE, null)
            // A different date (or none) means there is no floor for today. Yesterday's
            // total must never floor today's.
            val stored = if (storedDate == localDate) {
                prefs.getFloat(KEY_MINUTES, 0f).toDouble()
            } else {
                0.0
            }

            if (minutes < stored) {
                Log.w(
                    TAG,
                    "Derived total $minutes min is below the $stored min already posted " +
                        "for $localDate — posting the floor. The device clock or time " +
                        "zone most likely moved backward.",
                )
                return@runCatching stored
            }

            if (minutes > stored || storedDate != localDate) {
                prefs.edit()
                    .putString(KEY_DATE, localDate)
                    .putFloat(KEY_MINUTES, minutes.toFloat())
                    .apply()
            }
            minutes
        }.getOrElse {
            Log.w(TAG, "Could not read or write the posted-total floor", it)
            minutes
        }
}
