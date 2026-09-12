package com.nestimer.agent.net

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The parts of `/agent/config` this client needs.
 *
 * Every field has a default. The server may add fields, and older deployments may omit
 * the newer optional ones; neither should stop the app from reporting. Activities,
 * downtime and the bonus window are decoded but unused — this client never locks.
 */
@Serializable
data class AgentConfigDto(
    @SerialName("downtime_enabled") val downtimeEnabled: Boolean = false,
    @SerialName("downtime_start") val downtimeStart: String = "22:00",
    @SerialName("downtime_end") val downtimeEnd: String = "08:00",
    @SerialName("screen_time_enabled") val screenTimeEnabled: Boolean = false,
    @SerialName("screen_time_limit_minutes") val screenTimeLimitMinutes: Int = 0,
    @SerialName("used_minutes_today") val usedMinutesToday: Double = 0.0,
    @SerialName("device_used_minutes") val deviceUsedMinutes: Double = 0.0,
    @SerialName("device_cap_minutes") val deviceCapMinutes: Int? = null,
) {
    /**
     * Minutes left before the child runs out, or null when nothing limits them.
     *
     * The same `min(shared, per-device)` the Mac agent evaluates. This client does not
     * act on it — it only displays it — but showing a different number than the Mac
     * would read as a bug to the child, who checks both.
     */
    val remainingMinutes: Double?
        get() {
            if (!screenTimeEnabled) return null
            val shared = screenTimeLimitMinutes - usedMinutesToday
            val capped = deviceCapMinutes?.let { it - deviceUsedMinutes }
            return maxOf(0.0, minOf(shared, capped ?: shared))
        }
}

@Serializable
data class UsageReportDto(
    val date: String,
    @SerialName("total_minutes") val totalMinutes: Double,
)
