package com.nestimer.agent.ui

import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.content.ContextCompat
import com.nestimer.agent.data.Pairing
import com.nestimer.agent.service.CountingService

/**
 * Pairing plus the four grants the service needs.
 *
 * The checklist is the point: three of these cannot be requested programmatically or
 * can be silently declined, and a service missing any of them goes quiet in a way that
 * looks identical to a child who disabled it.
 */
class SetupActivity : ComponentActivity() {

    private lateinit var status: TextView
    private lateinit var input: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 64, 48, 48)
            layoutParams = ViewGroup.LayoutParams(MATCH, MATCH)
        }

        root.addView(TextView(this).apply {
            text = "NesTimer"
            textSize = 28f
        })

        root.addView(TextView(this).apply {
            text = "Paste the setup string from the parent app:"
            textSize = 15f
            setPadding(0, 48, 0, 12)
        })

        input = EditText(this).apply {
            hint = "https://my.nestimer.com|token"
            setSingleLine(false)
        }
        root.addView(input)

        root.addView(Button(this).apply {
            text = "Pair this phone"
            setOnClickListener { pair() }
        })

        status = TextView(this).apply {
            textSize = 14f
            setPadding(0, 48, 0, 0)
        }
        root.addView(status)

        root.addView(Button(this).apply {
            text = "Grant usage access"
            setOnClickListener { startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)) }
        })

        root.addView(Button(this).apply {
            text = "Allow notifications"
            setOnClickListener { requestNotifications() }
        })

        root.addView(Button(this).apply {
            text = "Ignore battery optimisation"
            setOnClickListener { requestBatteryExemption() }
        })

        setContentView(root)
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
        if (Pairing.load(this) != null && hasUsageAccess()) {
            CountingService.start(this)
        }
    }

    private fun pair() {
        val parsed = Pairing.parse(input.text.toString())
        if (parsed == null) {
            Toast.makeText(this, "Expected: server|token", Toast.LENGTH_LONG).show()
            return
        }
        Pairing.save(this, parsed.server, parsed.token)
        Toast.makeText(this, "Paired with ${parsed.server}", Toast.LENGTH_LONG).show()
        refreshStatus()
    }

    private fun refreshStatus() {
        fun mark(ok: Boolean) = if (ok) "OK" else "MISSING"
        status.text = buildString {
            appendLine("Paired: ${mark(Pairing.load(this@SetupActivity) != null)}")
            appendLine("Usage access: ${mark(hasUsageAccess())}")
            appendLine("Notifications: ${mark(hasNotifications())}")
            appendLine("Battery exemption: ${mark(hasBatteryExemption())}")
            appendLine()
            append(
                if (isReady()) "Reporting. Leave this app installed."
                else "Not reporting yet — grant everything marked MISSING."
            )
        }
    }

    private fun isReady() =
        Pairing.load(this) != null && hasUsageAccess() && hasNotifications() && hasBatteryExemption()

    private fun hasUsageAccess(): Boolean {
        val ops = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = ops.unsafeCheckOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS,
            android.os.Process.myUid(),
            packageName,
        )
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun hasNotifications(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.POST_NOTIFICATIONS,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
    }

    private fun hasBatteryExemption(): Boolean {
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    @Suppress("BatteryLife") // deliberate: the service dies within hours without it
    private fun requestBatteryExemption() {
        startActivity(
            Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName"),
            )
        )
    }

    private companion object {
        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
    }
}
