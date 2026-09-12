package com.nestimer.agent.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.nestimer.agent.data.Pairing

/**
 * Bring the service back after a reboot, but only once the device is paired.
 *
 * Starting the service without usage access would not crash anything by itself —
 * `CountingService.reportOnce` gates on `UsageAccess.isGranted` before it does
 * anything — but checking here too avoids starting a service that can only ever
 * sit idle, and keeps the "only start when it can actually do its job" rule in one
 * obvious place for both entry points into the service.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (Pairing.load(context) == null) return
        if (!UsageAccess.isGranted(context)) return
        CountingService.start(context)
    }
}
