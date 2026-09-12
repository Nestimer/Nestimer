package com.nestimer.agent.service

import android.app.AppOpsManager
import android.content.Context
import android.os.Process

/**
 * Whether this app currently holds the special "usage access" grant.
 *
 * `UsageStatsManager.queryEvents` does NOT throw when this is missing — it silently
 * returns an empty event stream, which `UsageCounter.foregroundMinutes` would then
 * read as a confident 0.0. Since `/agent/usage` treats a posted value as an absolute
 * set (not a delta) and a device's usage feeds a sum across all the child's devices,
 * posting a 0.0 here would erase the day's real total and unlock every device on the
 * account. Every call site that is about to count or report MUST check this first
 * and skip reporting entirely when it is false — never post a manufactured zero.
 *
 * Shared by `CountingService`, `BootReceiver` and `SetupActivity` so there is exactly
 * one place this reasoning lives.
 */
object UsageAccess {
    fun isGranted(context: Context): Boolean {
        val ops = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = ops.unsafeCheckOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS,
            Process.myUid(),
            context.packageName,
        )
        return mode == AppOpsManager.MODE_ALLOWED
    }
}
