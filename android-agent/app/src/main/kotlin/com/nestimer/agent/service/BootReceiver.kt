package com.nestimer.agent.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.nestimer.agent.data.Pairing

/** Bring the service back after a reboot, but only once the device is paired. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (Pairing.load(context) == null) return
        CountingService.start(context)
    }
}
