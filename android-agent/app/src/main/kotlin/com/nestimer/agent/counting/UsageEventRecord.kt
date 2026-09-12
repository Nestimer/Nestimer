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
) {
    companion object {
        /**
         * The package name an [EventType.ALL_STOPPED] record carries.
         *
         * That event is about the device, not about one app, and the platform does not
         * reliably attach a package to it — so the field is deliberately meaningless
         * there rather than pretending to name a responsible app.
         */
        const val NO_PACKAGE = ""

        /** An "everything foreground ended here" marker at [timestampMillis]. */
        fun allStopped(timestampMillis: Long) =
            UsageEventRecord(NO_PACKAGE, EventType.ALL_STOPPED, timestampMillis)
    }
}

/**
 * What a record means to [UsageCounter].
 *
 * These are semantics, not platform constants: the mapping from
 * `UsageEvents.Event.*` lives in `EventReader`, which is the only file allowed to know
 * the numbers.
 */
enum class EventType {
    /** This package came to the foreground — open a session for it. */
    RESUMED,

    /** This package left the foreground — close its session. */
    PAUSED,

    /**
     * This package's activity was fully stopped.
     *
     * In the normal lifecycle this arrives just after [PAUSED] and is a no-op. It
     * matters only when the [PAUSED] never came: it then closes the session that would
     * otherwise hang open.
     */
    STOPPED,

    /**
     * Every open session ended here, whatever package it belonged to.
     *
     * The device shut down, booted, or the screen went non-interactive. Android emits
     * no per-app [PAUSED] for whatever was foreground across a shutdown — that is the
     * documented contract of `DEVICE_SHUTDOWN` ("should be treated as if all started
     * activities … are now stopped and no explicit ACTIVITY_STOPPED … events will be
     * generated for them") — and on a flat battery there is no lifecycle event at all.
     * Without this, the session that was open when the phone died stays open and every
     * later tick re-extends it to *now*, billing the whole powered-off period to the
     * child's shared daily budget.
     */
    ALL_STOPPED,
}
