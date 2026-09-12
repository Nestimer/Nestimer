package com.nestimer.agent.counting

/**
 * One foreground transition, stripped of Android types.
 *
 * The service converts `android.app.usage.UsageEvents.Event` into these; keeping the
 * counter's input framework-free is what lets a JVM unit test reach the algorithm.
 */
data class UsageEventRecord(
    val packageName: String,
    val type: EventType,
    val timestampMillis: Long,
)

enum class EventType { RESUMED, PAUSED }
