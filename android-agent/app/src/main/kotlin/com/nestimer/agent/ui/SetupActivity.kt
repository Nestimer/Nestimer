package com.nestimer.agent.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.text.InputType
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.nestimer.agent.data.Pairing
import com.nestimer.agent.service.CountingService
import com.nestimer.agent.service.UsageAccess

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
            setPadding(dp(24), dp(32), dp(24), dp(24))
            layoutParams = ViewGroup.LayoutParams(MATCH, MATCH)
        }

        root.addView(TextView(this).apply {
            text = "NesTimer"
            textSize = 28f
        })

        root.addView(TextView(this).apply {
            text = "Paste the setup string from the parent app:"
            textSize = 15f
            setPadding(0, dp(24), 0, dp(6))
        })

        input = EditText(this).apply {
            hint = "https://my.nestimer.com|token"
            setSingleLine(false)
            // Some IMEs auto-capitalise a typed URL into "Https://", which then fails
            // Pairing.parse's scheme check. textUri disables that; noSuggestions stops
            // autocorrect mangling the token half.
            inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_VARIATION_URI or
                InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        }
        root.addView(input)

        root.addView(Button(this).apply {
            text = "Pair this phone"
            setOnClickListener { pair() }
        })

        status = TextView(this).apply {
            textSize = 14f
            setPadding(0, dp(24), 0, 0)
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

        // A ScrollView keeps every control reachable on a short screen or in
        // landscape; the inset listener keeps the title out from under the status
        // bar and the last button out from under the gesture bar now that targetSdk
        // 35 draws edge-to-edge by default.
        val scroll = ScrollView(this).apply {
            layoutParams = ViewGroup.LayoutParams(MATCH, MATCH)
            addView(root)
        }
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.updatePadding(left = bars.left, top = bars.top, right = bars.right, bottom = bars.bottom)
            insets
        }

        setContentView(scroll)
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
        startIfReady()
    }

    private fun pair() {
        val parsed = Pairing.parse(input.text.toString())
        if (parsed == null) {
            Toast.makeText(
                this,
                "Expected: server|token — server must start with https:// (or http:// for local testing)",
                Toast.LENGTH_LONG,
            ).show()
            return
        }
        Pairing.save(this, parsed.server, parsed.token)
        Toast.makeText(this, "Paired with ${parsed.server}", Toast.LENGTH_LONG).show()
        refreshStatus()
        startIfReady()
    }

    /**
     * Starts the service once the two grants it cannot run without exist. Called from
     * both `pair()` and `onResume()`: on a fresh install the natural order is grant
     * permissions first and paste the setup string last, and `pair()` alone used to
     * leave the service unstarted until the next time the screen resumed.
     */
    private fun startIfReady() {
        if (Pairing.load(this) != null && UsageAccess.isGranted(this)) {
            CountingService.start(this)
        }
    }

    private fun refreshStatus() {
        fun mark(ok: Boolean) = if (ok) "OK" else "MISSING"

        // Loaded once and reused below rather than calling Pairing.load (Keystore +
        // file I/O) three separate times in one refresh.
        val paired = Pairing.load(this) != null
        val usageAccess = UsageAccess.isGranted(this)
        val notifications = hasNotifications()
        val batteryExemption = hasBatteryExemption()

        // Two honest, distinct claims rather than one: the service is started on
        // (paired && usage access) alone, so a device missing only notifications or
        // battery exemption IS already reporting — it just might not survive being
        // killed. Saying "Not reporting yet" in that case was simply false.
        val reportingNow = paired && usageAccess
        val willSurvive = notifications && batteryExemption

        status.text = buildString {
            appendLine("Paired: ${mark(paired)}")
            appendLine("Usage access: ${mark(usageAccess)}")
            appendLine("Notifications: ${mark(notifications)}")
            appendLine("Battery exemption: ${mark(batteryExemption)}")
            appendLine()
            append(
                when {
                    reportingNow && willSurvive -> "Reporting. Leave this app installed."
                    reportingNow -> "Reporting now, but may not survive being killed — " +
                        "grant everything above marked MISSING to make it reliable."
                    else -> "Not reporting yet — grant everything marked MISSING above."
                }
            )
        }
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

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private companion object {
        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
    }
}
