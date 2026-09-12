# Android Usage Counter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an Android app that reports the child's foreground time to NesTimer so phone usage drains the same daily budget as the Mac.

**Architecture:** Three layers. `UsageCounter` and `AgentClient` are pure Kotlin with no `android.*` imports, so JVM tests in CI verify them without a device or emulator. `CountingService` is the only Android-aware layer and is verified by hand on the phone. The counter holds no state: every tick re-derives the day's total from `UsageStatsManager`'s event history, so a force-stop forfeits only the window the app was dead and the agent-2.9 echo bug cannot occur.

**Tech Stack:** Kotlin 2.0, Gradle (wrapper committed), AGP 8.7, OkHttp 4.12, kotlinx.serialization 1.7, JUnit 5, OkHttp MockWebServer. Command-line SDK only — no Android Studio.

**Spec:** `docs/superpowers/specs/2026-09-12-android-counter-design.md`

## Global Constraints

- `applicationId = "com.nestimer.agent"` — final from the first install; changing it later is a new app.
- `minSdk = 29`, `targetSdk = 35`, `compileSdk = 35`.
- `versionCode` is a monotonic integer starting at 1; Play rejects a re-used one forever. `versionName` starts at `"1.0"`.
- **No blocking, ever.** No lock screen, no overlay, no TOTP, no `SYSTEM_ALERT_WINDOW`. If a task seems to need one, the task is wrong.
- `counting/` and `net/` must not import `android.*`. This is what makes CI meaningful; a JVM unit test cannot load the Android framework.
- Auth is `Authorization: Bearer <api_token>` — the device JWT, same as the Mac agent (`macos-agent/NesTimerAgent/Services/APIClient.swift:163`).
- Dates sent to the API are the device's **local** date as `YYYY-MM-DD`, matching `?date=` on `/agent/config`.
- All text in English. No Russian anywhere.
- Conventional commits (`feat:`, `fix:`, `ci:`, `docs:`, `chore:`).
- Toolchain env for every Gradle command:
  ```bash
  export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
  export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
  ```

## File Structure

| File | Responsibility |
|---|---|
| `android-agent/settings.gradle.kts` | Module list, repositories |
| `android-agent/build.gradle.kts` | Plugin versions |
| `android-agent/gradle.properties` | AndroidX, JVM args |
| `android-agent/gradle/wrapper/*` | Committed wrapper — CI and a fresh Mac need no Gradle install |
| `android-agent/app/build.gradle.kts` | SDK levels, deps, signing, `local.properties` keystore lookup |
| `app/src/main/kotlin/.../counting/UsageCounter.kt` | Pure: events → foreground minutes. The only non-trivial algorithm in the app |
| `app/src/main/kotlin/.../counting/UsageEventRecord.kt` | Pure data class + `EventType` |
| `app/src/main/kotlin/.../net/Dto.kt` | Pure: wire types, `ignoreUnknownKeys` |
| `app/src/main/kotlin/.../net/AgentClient.kt` | Pure: two HTTP calls |
| `app/src/main/kotlin/.../data/Pairing.kt` | Android: `EncryptedSharedPreferences` for `server\|token` |
| `app/src/main/kotlin/.../service/EventReader.kt` | Android: `UsageStatsManager` → `List<UsageEventRecord>` |
| `app/src/main/kotlin/.../service/CountingService.kt` | Android: foreground service, 60s tick, notification |
| `app/src/main/kotlin/.../service/BootReceiver.kt` | Android: restart on boot |
| `app/src/main/kotlin/.../ui/SetupActivity.kt` | Android: pairing + the four-permission checklist |
| `app/src/main/AndroidManifest.xml` | Permissions, FGS type, receiver |
| `app/src/test/kotlin/...` | JVM unit tests |
| `.github/workflows/ci.yml` | New `android-build` job |
| `ParentApp/NesTimer/Models/Models.swift` | `isStale` / `staleLabel` on `Device` |
| `ParentApp/NesTimer/Views/DevicesListView.swift` | Render the quiet warning |
| `ParentApp/NesTimer/Views/DeviceDetailView.swift` | Render the quiet warning |

Not touched: `api/` (no endpoints, no migrations), `web-dashboard/` (silence detection already shipped there).

---

### Task 1: Gradle skeleton that builds and tests

**Files:**
- Create: `android-agent/settings.gradle.kts`, `android-agent/build.gradle.kts`, `android-agent/gradle.properties`, `android-agent/.gitignore`
- Create: `android-agent/app/build.gradle.kts`, `android-agent/app/src/main/AndroidManifest.xml`
- Create: `android-agent/gradle/wrapper/gradle-wrapper.properties`, `gradle-wrapper.jar`, `android-agent/gradlew`
- Test: `android-agent/app/src/test/kotlin/com/nestimer/agent/SmokeTest.kt`

**Interfaces:**
- Consumes: nothing.
- Produces: a working `./gradlew test` and `./gradlew assembleDebug` from `android-agent/`.

- [ ] **Step 1: Generate the wrapper**

Gradle is needed once, only to emit the wrapper; after this it is committed and the brew copy can go.

```bash
brew install gradle
mkdir -p /Users/ex/GitHub/Nestimer/android-agent
cd /Users/ex/GitHub/Nestimer/android-agent
gradle wrapper --gradle-version 8.11.1 --distribution-type bin
ls -la gradlew gradle/wrapper/
```

Expected: `gradlew`, `gradle/wrapper/gradle-wrapper.jar`, `gradle/wrapper/gradle-wrapper.properties`.

- [ ] **Step 2: Write the build files**

`android-agent/settings.gradle.kts`:

```kotlin
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "nestimer-agent"
include(":app")
```

`android-agent/build.gradle.kts`:

```kotlin
plugins {
    id("com.android.application") version "8.7.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.0.21" apply false
}
```

`android-agent/gradle.properties`:

```properties
org.gradle.jvmargs=-Xmx2048m
android.useAndroidX=true
kotlin.code.style=official
```

`android-agent/.gitignore`:

```gitignore
.gradle/
build/
local.properties
*.keystore
*.jks
```

`android-agent/app/build.gradle.kts`:

```kotlin
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.nestimer.agent"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.nestimer.agent"
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets {
        getByName("main").java.srcDirs("src/main/kotlin")
        getByName("test").java.srcDirs("src/test/kotlin")
    }

    testOptions {
        unitTests.all { it.useJUnitPlatform() }
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    testImplementation("org.junit.jupiter:junit-jupiter:5.11.3")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}
```

`android-agent/app/src/main/AndroidManifest.xml` — minimal for now; permissions arrive in Task 4:

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="NesTimer"
        android:allowBackup="false" />
</manifest>
```

- [ ] **Step 3: Write the smoke test**

This exists to prove the JVM test harness runs at all, before any real logic depends on it.

`android-agent/app/src/test/kotlin/com/nestimer/agent/SmokeTest.kt`:

```kotlin
package com.nestimer.agent

import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class SmokeTest {
    @Test
    fun `the JVM test harness runs`() {
        assertTrue(true)
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
cd /Users/ex/GitHub/Nestimer/android-agent
export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
./gradlew test
```

Expected: PASS. The first run downloads Gradle and the Android plugin; several minutes is normal.

- [ ] **Step 5: Verify a debug APK builds**

```bash
./gradlew assembleDebug
ls -la app/build/outputs/apk/debug/
```

Expected: `app-debug.apk` exists.

- [ ] **Step 6: Add the CI job**

Append to `.github/workflows/ci.yml`, as a sibling of the existing jobs (2-space indent under `jobs:`):

```yaml
  # ─── Android agent (Kotlin unit tests + APK) ───
  android-build:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: android-agent

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "21"
          cache: gradle

      - uses: android-actions/setup-android@v3

      # Unit tests first: they cover UsageCounter and AgentClient, the only two
      # layers a machine can check. Everything else on this platform is verified
      # by hand on the phone, so a green job here means exactly these two passed.
      - name: Unit tests
        run: ./gradlew test

      - name: Build debug APK
        run: ./gradlew assembleDebug
```

- [ ] **Step 7: Commit**

```bash
cd /Users/ex/GitHub/Nestimer
git add android-agent .github/workflows/ci.yml
git commit -m "feat: Android agent Gradle skeleton and CI job"
```

---

### Task 2: UsageCounter

The only non-trivial algorithm in the app. Everything else is plumbing.

**Files:**
- Create: `android-agent/app/src/main/kotlin/com/nestimer/agent/counting/UsageEventRecord.kt`
- Create: `android-agent/app/src/main/kotlin/com/nestimer/agent/counting/UsageCounter.kt`
- Test: `android-agent/app/src/test/kotlin/com/nestimer/agent/counting/UsageCounterTest.kt`

**Interfaces:**
- Consumes: Task 1's build.
- Produces:
  - `data class UsageEventRecord(packageName: String, type: EventType, timestampMillis: Long)`
  - `enum class EventType { RESUMED, PAUSED }`
  - `UsageCounter.foregroundMinutes(events: List<UsageEventRecord>, startOfDayMillis: Long, nowMillis: Long): Double`

- [ ] **Step 1: Write the failing tests**

`android-agent/app/src/test/kotlin/com/nestimer/agent/counting/UsageCounterTest.kt`:

```kotlin
package com.nestimer.agent.counting

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

private const val DAY_START = 1_757_635_200_000L // arbitrary local midnight
private fun min(n: Long) = DAY_START + n * 60_000L

private fun resumed(pkg: String, atMinute: Long) =
    UsageEventRecord(pkg, EventType.RESUMED, min(atMinute))

private fun paused(pkg: String, atMinute: Long) =
    UsageEventRecord(pkg, EventType.PAUSED, min(atMinute))

class UsageCounterTest {

    @Test
    fun `no events is zero, not a crash`() {
        val total = UsageCounter.foregroundMinutes(emptyList(), DAY_START, min(600))
        assertEquals(0.0, total, 0.001)
    }

    @Test
    fun `a single resume-pause pair counts its length`() {
        val events = listOf(resumed("com.chrome", 10), paused("com.chrome", 25))
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(15.0, total, 0.001)
    }

    @Test
    fun `an app still in the foreground counts up to now, not to zero`() {
        val events = listOf(resumed("com.chrome", 10))
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(40))
        assertEquals(30.0, total, 0.001)
    }

    @Test
    fun `a pause with no resume counts from the start of the day`() {
        // The session began before local midnight, so queryEvents never returns its
        // RESUMED. Counting from zero would silently lose the morning.
        val events = listOf(paused("com.chrome", 20))
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(20.0, total, 0.001)
    }

    @Test
    fun `a handoff between apps is one timeline, not two sessions added up`() {
        // Chrome 10..30, YouTube 28..50. Overlap is 28..30. Summing per package
        // gives 20 + 22 = 42; the truth is 10..50 = 40.
        val events = listOf(
            resumed("com.chrome", 10),
            resumed("com.youtube", 28),
            paused("com.chrome", 30),
            paused("com.youtube", 50),
        )
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(40.0, total, 0.001)
    }

    @Test
    fun `two separate sessions with a gap are both counted`() {
        val events = listOf(
            resumed("com.chrome", 10), paused("com.chrome", 20),
            resumed("com.chrome", 100), paused("com.chrome", 115),
        )
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(35.0, total, 0.001)
    }

    @Test
    fun `events out of order are handled - the API does not guarantee ordering`() {
        val events = listOf(
            paused("com.chrome", 20),
            resumed("com.chrome", 10),
        )
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(10.0, total, 0.001)
    }

    @Test
    fun `a repeated resume with no pause between keeps the earlier start`() {
        val events = listOf(
            resumed("com.chrome", 10),
            resumed("com.chrome", 15),
            paused("com.chrome", 25),
        )
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(15.0, total, 0.001)
    }

    @Test
    fun `timestamps outside the window are clamped into it`() {
        val before = UsageEventRecord("com.chrome", EventType.RESUMED, DAY_START - 3_600_000L)
        val events = listOf(before, paused("com.chrome", 20))
        val total = UsageCounter.foregroundMinutes(events, DAY_START, min(600))
        assertEquals(20.0, total, 0.001)
    }

    @Test
    fun `now before the start of the day is zero, not negative`() {
        val events = listOf(resumed("com.chrome", 10))
        val total = UsageCounter.foregroundMinutes(events, DAY_START, DAY_START - 1000)
        assertEquals(0.0, total, 0.001)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/ex/GitHub/Nestimer/android-agent && ./gradlew test --tests '*UsageCounterTest*'
```

Expected: FAIL — unresolved reference `UsageCounter` / `UsageEventRecord`.

- [ ] **Step 3: Write the data types**

`counting/UsageEventRecord.kt`:

```kotlin
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
```

- [ ] **Step 4: Write the counter**

`counting/UsageCounter.kt`:

```kotlin
package com.nestimer.agent.counting

object UsageCounter {

    /**
     * Foreground minutes within [startOfDayMillis, nowMillis].
     *
     * Foreground is a single timeline, not a per-package sum. When one app hands off to
     * another the two sessions overlap for a moment, and adding them would count that
     * moment twice — so sessions are unioned before they are measured.
     *
     * This is recomputed from scratch on every tick. The app keeps no running tally, so
     * there is nothing to lose when the process dies and nothing to reconcile against
     * the server's total.
     *
     * The launcher and the system UI count too, because the screen is genuinely in use
     * while they are foreground. Filtering them would need a package allowlist that
     * drifts with every OEM and Android release, and would quietly under-count.
     */
    fun foregroundMinutes(
        events: List<UsageEventRecord>,
        startOfDayMillis: Long,
        nowMillis: Long,
    ): Double {
        if (nowMillis <= startOfDayMillis) return 0.0
        val millis = merge(sessions(events, startOfDayMillis, nowMillis))
            .sumOf { (start, end) -> end - start }
        return millis / 60_000.0
    }

    /**
     * Pair each RESUMED with that package's next PAUSED.
     *
     * An unmatched RESUMED means the app is in the foreground right now, so its session
     * runs to [nowMillis]. An unmatched PAUSED means the session opened before the
     * window did — before local midnight — so it runs from [startOfDayMillis].
     */
    private fun sessions(
        events: List<UsageEventRecord>,
        startOfDayMillis: Long,
        nowMillis: Long,
    ): List<Pair<Long, Long>> {
        val ordered = events
            .map { it.copy(timestampMillis = it.timestampMillis.coerceIn(startOfDayMillis, nowMillis)) }
            .sortedBy { it.timestampMillis }

        val out = mutableListOf<Pair<Long, Long>>()
        val open = mutableMapOf<String, Long>()

        for (event in ordered) {
            when (event.type) {
                // A second RESUMED with no PAUSED between keeps the earlier start.
                EventType.RESUMED -> open.putIfAbsent(event.packageName, event.timestampMillis)
                EventType.PAUSED -> {
                    val start = open.remove(event.packageName) ?: startOfDayMillis
                    if (event.timestampMillis > start) out += start to event.timestampMillis
                }
            }
        }
        for (start in open.values) {
            if (nowMillis > start) out += start to nowMillis
        }
        return out
    }

    private fun merge(intervals: List<Pair<Long, Long>>): List<Pair<Long, Long>> {
        if (intervals.isEmpty()) return emptyList()
        val sorted = intervals.sortedBy { it.first }
        val out = mutableListOf(sorted.first())
        for ((start, end) in sorted.drop(1)) {
            val (lastStart, lastEnd) = out.last()
            if (start <= lastEnd) out[out.lastIndex] = lastStart to maxOf(lastEnd, end)
            else out += start to end
        }
        return out
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/ex/GitHub/Nestimer/android-agent && ./gradlew test --tests '*UsageCounterTest*'
```

Expected: PASS, 10 tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/ex/GitHub/Nestimer
git add android-agent/app/src
git commit -m "feat: stateless foreground-time counter for Android"
```

---

### Task 3: AgentClient and the wire types

**Files:**
- Create: `android-agent/app/src/main/kotlin/com/nestimer/agent/net/Dto.kt`
- Create: `android-agent/app/src/main/kotlin/com/nestimer/agent/net/AgentClient.kt`
- Test: `android-agent/app/src/test/kotlin/com/nestimer/agent/net/AgentClientTest.kt`
- Test: `android-agent/app/src/test/kotlin/com/nestimer/agent/net/RemainingMinutesTest.kt`

**Interfaces:**
- Consumes: nothing from Task 2.
- Produces:
  - `AgentConfigDto` with `screenTimeEnabled`, `screenTimeLimitMinutes`, `usedMinutesToday`, `deviceUsedMinutes`, `deviceCapMinutes`
  - `AgentConfigDto.remainingMinutes: Double?` — null when there is no limit
  - `class AgentClient(baseUrl: String, token: String, http: OkHttpClient = …)` with
    `postUsage(localDate: String, totalMinutes: Double): Boolean` and
    `fetchConfig(localDate: String, version: String): AgentConfigDto?`

- [ ] **Step 1: Write the failing tests**

`net/RemainingMinutesTest.kt`:

```kotlin
package com.nestimer.agent.net

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class RemainingMinutesTest {

    @Test
    fun `no limit when screen time is disabled`() {
        val config = AgentConfigDto(screenTimeEnabled = false, screenTimeLimitMinutes = 120)
        assertNull(config.remainingMinutes)
    }

    @Test
    fun `remaining is the shared budget minus the child's total`() {
        val config = AgentConfigDto(
            screenTimeEnabled = true,
            screenTimeLimitMinutes = 120,
            usedMinutesToday = 30.0,
        )
        assertEquals(90.0, config.remainingMinutes!!, 0.001)
    }

    @Test
    fun `a tighter per-device cap binds instead of the shared budget`() {
        // 90 left of the shared budget, but only 20 left of this device's own 60.
        val config = AgentConfigDto(
            screenTimeEnabled = true,
            screenTimeLimitMinutes = 120,
            usedMinutesToday = 30.0,
            deviceUsedMinutes = 40.0,
            deviceCapMinutes = 60,
        )
        assertEquals(20.0, config.remainingMinutes!!, 0.001)
    }

    @Test
    fun `remaining never goes below zero`() {
        val config = AgentConfigDto(
            screenTimeEnabled = true,
            screenTimeLimitMinutes = 120,
            usedMinutesToday = 200.0,
        )
        assertEquals(0.0, config.remainingMinutes!!, 0.001)
    }
}
```

`net/AgentClientTest.kt`:

```kotlin
package com.nestimer.agent.net

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test

class AgentClientTest {

    private lateinit var server: MockWebServer

    @BeforeEach
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @AfterEach
    fun tearDown() {
        server.shutdown()
    }

    private fun client() = AgentClient(server.url("/").toString(), "test-token")

    @Test
    fun `postUsage sends the bearer token, the date and an absolute total`() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"ok":true}"""))

        val ok = client().postUsage("2026-09-12", 42.5)

        assertTrue(ok)
        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/agent/usage", request.path)
        assertEquals("Bearer test-token", request.getHeader("Authorization"))
        val body = request.body.readUtf8()
        assertTrue(body.contains("\"date\":\"2026-09-12\""), body)
        assertTrue(body.contains("42.5"), body)
    }

    @Test
    fun `fetchConfig sends the local date and the version, and parses the response`() {
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """
                {"downtime_enabled":true,"downtime_start":"22:00","downtime_end":"08:00",
                 "screen_time_enabled":true,"screen_time_limit_minutes":120,
                 "used_minutes_today":35.5,"device_used_minutes":10.0,
                 "device_cap_minutes":60,"activities":[],"bonus_until":null}
                """.trimIndent()
            )
        )

        val config = client().fetchConfig("2026-09-12", "1.0")

        assertNotNull(config)
        assertEquals(120, config!!.screenTimeLimitMinutes)
        assertEquals(35.5, config.usedMinutesToday, 0.001)
        assertEquals(60, config.deviceCapMinutes)
        val request = server.takeRequest()
        assertEquals("GET", request.method)
        assertTrue(request.path!!.startsWith("/agent/config"), request.path!!)
        assertTrue(request.path!!.contains("date=2026-09-12"), request.path!!)
        assertTrue(request.path!!.contains("version=1.0"), request.path!!)
    }

    @Test
    fun `a response omitting every optional field parses instead of throwing`() {
        // The Mac agent has the same test for the same reason: a decoder that throws
        // leaves the device with no config at all. Here it would merely stop the
        // notification updating, but the failure mode is not worth inheriting.
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"downtime_enabled":false,"downtime_start":"22:00","downtime_end":"08:00",
                    "screen_time_enabled":true,"screen_time_limit_minutes":90,
                    "used_minutes_today":5.0}"""
            )
        )

        val config = client().fetchConfig("2026-09-12", "1.0")

        assertNotNull(config)
        assertEquals(0.0, config!!.deviceUsedMinutes, 0.001)
        assertNull(config.deviceCapMinutes)
    }

    @Test
    fun `an unknown field does not break parsing`() {
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"downtime_enabled":false,"downtime_start":"22:00","downtime_end":"08:00",
                    "screen_time_enabled":true,"screen_time_limit_minutes":90,
                    "used_minutes_today":5.0,"a_field_added_next_year":123}"""
            )
        )

        assertNotNull(client().fetchConfig("2026-09-12", "1.0"))
    }

    @Test
    fun `a server error returns null rather than throwing`() {
        server.enqueue(MockResponse().setResponseCode(500))
        assertNull(client().fetchConfig("2026-09-12", "1.0"))
    }

    @Test
    fun `a rejected token returns null rather than throwing`() {
        server.enqueue(MockResponse().setResponseCode(401))
        assertNull(client().fetchConfig("2026-09-12", "1.0"))
    }

    @Test
    fun `postUsage reports failure on a server error instead of throwing`() {
        server.enqueue(MockResponse().setResponseCode(500))
        assertEquals(false, client().postUsage("2026-09-12", 1.0))
    }

    @Test
    fun `a base URL with a trailing slash does not produce a double slash`() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("{}"))
        AgentClient(server.url("/").toString().trimEnd('/') + "/", "t").postUsage("2026-09-12", 1.0)
        assertEquals("/agent/usage", server.takeRequest().path)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/ex/GitHub/Nestimer/android-agent && ./gradlew test --tests '*net*'
```

Expected: FAIL — unresolved reference `AgentConfigDto` / `AgentClient`.

- [ ] **Step 3: Write the wire types**

`net/Dto.kt`:

```kotlin
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
```

- [ ] **Step 4: Write the client**

`net/AgentClient.kt`:

```kotlin
package com.nestimer.agent.net

import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * The two calls this app makes. Framework-free so a JVM test can drive it against a
 * MockWebServer.
 *
 * Every failure returns null or false rather than throwing: a tick that cannot reach
 * the server is not an error worth crashing a foreground service over, and the next
 * tick re-sends an absolute total, so nothing needs a retry queue.
 */
class AgentClient(
    baseUrl: String,
    private val token: String,
    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build(),
) {
    private val base = baseUrl.trimEnd('/')
    private val json = Json { ignoreUnknownKeys = true }

    fun postUsage(localDate: String, totalMinutes: Double): Boolean {
        val payload = json.encodeToString(UsageReportDto.serializer(), UsageReportDto(localDate, totalMinutes))
        val request = Request.Builder()
            .url("$base/agent/usage")
            .addHeader("Authorization", "Bearer $token")
            .post(payload.toRequestBody("application/json".toMediaType()))
            .build()
        return runCatching {
            http.newCall(request).execute().use { it.isSuccessful }
        }.getOrDefault(false)
    }

    fun fetchConfig(localDate: String, version: String): AgentConfigDto? {
        val url = "$base/agent/config".toHttpUrl().newBuilder()
            .addQueryParameter("date", localDate)
            .addQueryParameter("version", version)
            .build()
        val request = Request.Builder()
            .url(url)
            .addHeader("Authorization", "Bearer $token")
            .get()
            .build()
        return runCatching {
            http.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return null
                val body = response.body?.string() ?: return null
                json.decodeFromString(AgentConfigDto.serializer(), body)
            }
        }.getOrNull()
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/ex/GitHub/Nestimer/android-agent && ./gradlew test
```

Expected: PASS — all of Task 2's and Task 3's tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/ex/GitHub/Nestimer
git add android-agent/app/src
git commit -m "feat: Android agent API client and wire types"
```

---

### Task 4: The Android layer — service, event reader, boot receiver

Nothing here is unit-testable; it is verified by `assembleDebug` and then by hand in Task 8.

**Files:**
- Create: `android-agent/app/src/main/kotlin/com/nestimer/agent/data/Pairing.kt`
- Create: `android-agent/app/src/main/kotlin/com/nestimer/agent/service/EventReader.kt`
- Create: `android-agent/app/src/main/kotlin/com/nestimer/agent/service/CountingService.kt`
- Create: `android-agent/app/src/main/kotlin/com/nestimer/agent/service/BootReceiver.kt`
- Modify: `android-agent/app/src/main/AndroidManifest.xml`

**Interfaces:**
- Consumes: `UsageCounter.foregroundMinutes`, `UsageEventRecord`, `EventType`, `AgentClient`, `AgentConfigDto.remainingMinutes`.
- Produces: `Pairing.load(context): Pairing?` / `Pairing.save(context, server, token)`; `CountingService.start(context)`.

- [ ] **Step 1: Write the pairing store**

`data/Pairing.kt`:

```kotlin
package com.nestimer.agent.data

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * The `server|token` pair, in the same format the Mac agent's setup dialog parses
 * (`ParentApp/NesTimer/Views/AddDeviceView.swift:36`).
 *
 * The token is a device JWT that grants usage reporting for one device, so it lives in
 * EncryptedSharedPreferences rather than plain prefs.
 */
data class Pairing(val server: String, val token: String) {

    companion object {
        private const val FILE = "nestimer_pairing"
        private const val KEY_SERVER = "server"
        private const val KEY_TOKEN = "token"

        private fun prefs(context: Context) = EncryptedSharedPreferences.create(
            context,
            FILE,
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )

        fun load(context: Context): Pairing? {
            val p = prefs(context)
            val server = p.getString(KEY_SERVER, null) ?: return null
            val token = p.getString(KEY_TOKEN, null) ?: return null
            return Pairing(server, token)
        }

        fun save(context: Context, server: String, token: String) {
            prefs(context).edit().putString(KEY_SERVER, server).putString(KEY_TOKEN, token).apply()
        }

        /** Parse "https://my.nestimer.com|eyJ..." — split on the single "|", as the Mac does. */
        fun parse(setupString: String): Pairing? {
            val parts = setupString.trim().split("|")
            if (parts.size != 2) return null
            val server = parts[0].trim().trimEnd('/')
            val token = parts[1].trim()
            if (server.isEmpty() || token.isEmpty()) return null
            return Pairing(server, token)
        }
    }
}
```

- [ ] **Step 2: Write the event reader**

`service/EventReader.kt`:

```kotlin
package com.nestimer.agent.service

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import com.nestimer.agent.counting.EventType
import com.nestimer.agent.counting.UsageEventRecord

/**
 * The whole Android-specific part of counting: turn the platform's event stream into
 * the framework-free records `UsageCounter` understands.
 *
 * This history lives in the system, not in this process, which is why the counter can
 * be stateless and why a force-stop costs the child only the window the app was dead.
 */
class EventReader(private val context: Context) {

    fun eventsBetween(startMillis: Long, endMillis: Long): List<UsageEventRecord> {
        val manager = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val stream = manager.queryEvents(startMillis, endMillis)
        val out = mutableListOf<UsageEventRecord>()
        val event = UsageEvents.Event()
        while (stream.hasNextEvent()) {
            stream.getNextEvent(event)
            val type = when (event.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> EventType.RESUMED
                UsageEvents.Event.ACTIVITY_PAUSED -> EventType.PAUSED
                else -> null
            }
            if (type != null) {
                out += UsageEventRecord(event.packageName ?: continue, type, event.timeStamp)
            }
        }
        return out
    }
}
```

- [ ] **Step 3: Write the service**

`service/CountingService.kt`:

```kotlin
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
            .setSmallIcon(android.R.drawable.ic_lock_idle_clock)
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
```

- [ ] **Step 4: Write the boot receiver**

`service/BootReceiver.kt`:

```kotlin
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
```

- [ ] **Step 5: Write the manifest**

Replace `android-agent/app/src/main/AndroidManifest.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <!-- Special access: granted by hand in Settings, never programmatically. -->
    <uses-permission
        android:name="android.permission.PACKAGE_USAGE_STATS"
        tools:ignore="ProtectedPermissions" />

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />

    <application
        android:label="NesTimer"
        android:allowBackup="false"
        android:icon="@android:drawable/ic_lock_idle_clock">

        <activity
            android:name=".ui.SetupActivity"
            android:exported="true"
            android:label="NesTimer">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <service
            android:name=".service.CountingService"
            android:exported="false"
            android:foregroundServiceType="dataSync" />

        <receiver
            android:name=".service.BootReceiver"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED" />
            </intent-filter>
        </receiver>
    </application>
</manifest>
```

- [ ] **Step 6: Enable BuildConfig**

`CountingService` reads `BuildConfig.VERSION_NAME`. Add to the `android { }` block in `app/build.gradle.kts`:

```kotlin
    buildFeatures {
        buildConfig = true
    }
```

- [ ] **Step 7: Build**

This will not compile until Task 5 creates `SetupActivity`, which `CountingService` and the manifest both reference. Write Task 5 first, then run:

```bash
cd /Users/ex/GitHub/Nestimer/android-agent && ./gradlew assembleDebug
```

Expected: BUILD SUCCESSFUL.

- [ ] **Step 8: Commit (together with Task 5)**

---

### Task 5: SetupActivity — pairing and the permission checklist

**Files:**
- Create: `android-agent/app/src/main/kotlin/com/nestimer/agent/ui/SetupActivity.kt`
- Test: `android-agent/app/src/test/kotlin/com/nestimer/agent/data/PairingParseTest.kt`

**Interfaces:**
- Consumes: `Pairing.parse`, `Pairing.save`, `Pairing.load`, `CountingService.start`.
- Produces: the launcher activity.

- [ ] **Step 1: Write the failing parse tests**

`Pairing.parse` is pure, so it gets real tests; the UI around it does not.

`data/PairingParseTest.kt`:

```kotlin
package com.nestimer.agent.data

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class PairingParseTest {

    @Test
    fun `parses the same string the Mac agent accepts`() {
        val p = Pairing.parse("https://my.nestimer.com|eyJhbGciOi.abc.def")
        assertEquals("https://my.nestimer.com", p!!.server)
        assertEquals("eyJhbGciOi.abc.def", p.token)
    }

    @Test
    fun `trims surrounding whitespace from a pasted string`() {
        val p = Pairing.parse("  https://my.nestimer.com | token123  ")
        assertEquals("https://my.nestimer.com", p!!.server)
        assertEquals("token123", p.token)
    }

    @Test
    fun `strips a trailing slash so URLs never double up`() {
        assertEquals("https://my.nestimer.com", Pairing.parse("https://my.nestimer.com/|t")!!.server)
    }

    @Test
    fun `a bare token with no separator is rejected`() {
        // This is exactly what the parent app used to show, and what the Mac agent
        // rejected — the reason PR #3 existed. Fail loudly rather than half-pair.
        assertNull(Pairing.parse("eyJhbGciOi.abc.def"))
    }

    @Test
    fun `more than one separator is rejected`() {
        assertNull(Pairing.parse("https://a|b|c"))
    }

    @Test
    fun `an empty half is rejected`() {
        assertNull(Pairing.parse("https://my.nestimer.com|"))
        assertNull(Pairing.parse("|token"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/ex/GitHub/Nestimer/android-agent && ./gradlew test --tests '*PairingParseTest*'
```

Expected: FAIL — `Pairing` unresolved, unless Task 4 Step 1 is already committed, in which case these pass immediately. If they pass, that is fine: the parse logic was written with them in mind.

- [ ] **Step 3: Write the activity**

Built programmatically — the screen is a text field, a button and a four-row checklist, and an XML layout would add files without adding clarity.

`ui/SetupActivity.kt`:

```kotlin
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
```

- [ ] **Step 4: Add the activity dependency**

`ComponentActivity` needs androidx.activity. Add to `app/build.gradle.kts` dependencies:

```kotlin
    implementation("androidx.activity:activity-ktx:1.9.3")
```

- [ ] **Step 5: Build and test**

```bash
cd /Users/ex/GitHub/Nestimer/android-agent && ./gradlew test assembleDebug
```

Expected: all unit tests PASS, `app-debug.apk` produced.

- [ ] **Step 6: Commit Tasks 4 and 5 together**

They are one deliverable — neither compiles without the other.

```bash
cd /Users/ex/GitHub/Nestimer
git add android-agent
git commit -m "feat: Android counting service, pairing and setup screen"
```

---

### Task 6: Release signing and the install artifact

**Files:**
- Modify: `android-agent/app/build.gradle.kts`
- Create: `push-android-update.sh`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: a buildable app from Task 5.
- Produces: a signed release APK and a documented way to get it onto the phone.

- [ ] **Step 1: Generate the release keystore**

Kept out of git forever. Record the password with the other signing material.

```bash
export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
mkdir -p ~/.nestimer
"$JAVA_HOME/bin/keytool" -genkeypair -v \
  -keystore ~/.nestimer/nestimer-android.jks \
  -alias nestimer -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=NesTimer, O=NesTimer, C=UA"
```

- [ ] **Step 2: Wire signing into the build**

Create `android-agent/local.properties` (gitignored):

```properties
NESTIMER_KEYSTORE=/Users/ex/.nestimer/nestimer-android.jks
NESTIMER_KEYSTORE_PASSWORD=<the password you just set>
NESTIMER_KEY_ALIAS=nestimer
NESTIMER_KEY_PASSWORD=<the password you just set>
```

Add to `app/build.gradle.kts`, above `android { }`:

```kotlin
import java.util.Properties

val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
```

And inside `android { }`:

```kotlin
    signingConfigs {
        create("release") {
            val path = localProps.getProperty("NESTIMER_KEYSTORE")
            // CI has no keystore and only ever builds debug; skip rather than fail.
            if (path != null && file(path).exists()) {
                storeFile = file(path)
                storePassword = localProps.getProperty("NESTIMER_KEYSTORE_PASSWORD")
                keyAlias = localProps.getProperty("NESTIMER_KEY_ALIAS")
                keyPassword = localProps.getProperty("NESTIMER_KEY_PASSWORD")
            }
        }
    }
```

And in `buildTypes`:

```kotlin
        getByName("release") {
            isMinifyEnabled = false
            if (localProps.getProperty("NESTIMER_KEYSTORE") != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
```

- [ ] **Step 3: Build a signed release APK**

```bash
cd /Users/ex/GitHub/Nestimer/android-agent && ./gradlew assembleRelease
ls -la app/build/outputs/apk/release/
"$ANDROID_HOME/build-tools/35.0.0/apksigner" verify --print-certs app/build/outputs/apk/release/app-release.apk
```

Expected: `app-release.apk`, and `apksigner` reports the NesTimer certificate.

- [ ] **Step 4: Write the upload script**

The APK goes where the DMGs go — nginx serves `/download/` on `nestimer.com`
(`website/index.html:114` links `/download/NesTimer.dmg`). It does **not** go in
`data/agent-update/`; that directory backs `/agent/update/download` for the Mac
watchdog's auto-update, and nothing on Android can consume it.

Create `push-android-update.sh` at the repo root:

```bash
#!/bin/bash
# Build and publish the Android counter APK for sideloading.
# Usage: ./push-android-update.sh <server-host> <version>
# Example: ./push-android-update.sh 134.209.8.62 1.1
#
# Unlike push-agent-update.sh there is nothing to restart and nothing to notify:
# Android cannot update itself without Device Owner, so this only puts a file
# where a human can download it.
set -euo pipefail

SERVER="${1:-}"
VERSION="${2:-}"

if [ -z "$SERVER" ] || [ -z "$VERSION" ]; then
    echo "Usage: $0 <server-host-or-ip> <version>"
    echo "Example: $0 134.209.8.62 1.1"
    exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
GRADLE_FILE="$ROOT/android-agent/app/build.gradle.kts"
APK="$ROOT/android-agent/app/build/outputs/apk/release/app-release.apk"
REMOTE_DIR="/var/www/nestimer/download"

export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

# versionCode must increase monotonically and can never be reused once the app is
# on Play, so derive it from the existing value rather than from the version name.
CURRENT_CODE=$(grep -E '^\s*versionCode = ' "$GRADLE_FILE" | head -1 | grep -oE '[0-9]+')
NEXT_CODE=$((CURRENT_CODE + 1))
echo "versionCode $CURRENT_CODE -> $NEXT_CODE, versionName -> $VERSION"

sed -i '' "s/versionCode = $CURRENT_CODE/versionCode = $NEXT_CODE/" "$GRADLE_FILE"
sed -i '' "s/versionName = \"[^\"]*\"/versionName = \"$VERSION\"/" "$GRADLE_FILE"

echo "Building signed release..."
(cd "$ROOT/android-agent" && ./gradlew --quiet assembleRelease)

if [ ! -f "$APK" ]; then
    echo "ERROR: $APK not found after build."
    exit 1
fi

# Fail before uploading an unsigned APK — an unsigned one installs nowhere.
echo "Verifying signature..."
if ! "$ANDROID_HOME/build-tools/35.0.0/apksigner" verify --print-certs "$APK"; then
    echo "ERROR: apksigner rejected the APK. Is local.properties configured?"
    exit 1
fi

# The path is asserted, not guessed: fail loudly if the download dir moved.
if ! ssh "root@$SERVER" "[ -d '$REMOTE_DIR' ]"; then
    echo "ERROR: $REMOTE_DIR does not exist on $SERVER."
    echo "       Find where the DMGs are served from and update REMOTE_DIR."
    exit 1
fi

scp "$APK" "root@$SERVER:$REMOTE_DIR/NesTimerAgent.apk"
ssh "root@$SERVER" "echo '$VERSION' > $REMOTE_DIR/NesTimerAgent.apk.version"

echo ""
echo "=== Done ==="
echo "Version $VERSION (code $NEXT_CODE) uploaded."
echo "Download: https://nestimer.com/download/NesTimerAgent.apk"
echo ""
echo "This does NOT reach any phone by itself — install it by hand."
```

Then:

```bash
cd /Users/ex/GitHub/Nestimer && chmod +x push-android-update.sh
bash -n push-android-update.sh   # syntax check without running it
```

Expected: no output from `bash -n`.

- [ ] **Step 5: Document it**

Add to `CLAUDE.md` under "Build commands":

```markdown
# Android agent (child-side counter)
export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
cd android-agent && ./gradlew test assembleDebug
```

And under "Deployment":

```markdown
# Android agent update (from dev Mac) — sideload, no auto-update
./push-android-update.sh <version>
# Then install by hand on the phone: the APK cannot push itself.
```

And a new row in "Files you'll touch most": `Android counting logic` → `android-agent/app/src/main/kotlin/com/nestimer/agent/counting/UsageCounter.kt`.

Add to "Known sharp edges":

```markdown
9. **Android has no auto-update** — no watchdog, no Device Owner. A stale APK stays
   stale until someone reinstalls it by hand. Check `agent_version` in the dashboard,
   not the fact that the build succeeded.
```

- [ ] **Step 6: Commit**

```bash
cd /Users/ex/GitHub/Nestimer
git add android-agent/app/build.gradle.kts push-android-update.sh CLAUDE.md
git commit -m "feat: signed Android release build and sideload script"
```

---

### Task 7: Silence detection in the parent app

The web dashboard already does this (`web-dashboard/src/pages/DevicesPage.jsx`). This brings the parent app to parity, using the same threshold and the same wording so the two surfaces cannot disagree.

**Files:**
- Modify: `ParentApp/NesTimer/Models/Models.swift:80-131`
- Modify: `ParentApp/NesTimer/Views/DevicesListView.swift:91-99`
- Modify: `ParentApp/NesTimer/Views/DeviceDetailView.swift:379`

**Interfaces:**
- Consumes: `Device.lastSeenDate` (already present).
- Produces: `Device.isStale: Bool`, `Device.staleLabel: String`.

- [ ] **Step 1: Add the model properties**

In `ParentApp/NesTimer/Models/Models.swift`, after `lastSeenText` inside `struct Device`:

```swift
    /// A device is stale when it hasn't reported in over 15 minutes -- several missed
    /// 60s ticks, not one. This is the compensating control for platforms the agent
    /// can't forcibly lock: on Android the child can force-stop the app or revoke usage
    /// access, and without this the bypass is both free and invisible.
    ///
    /// Kept identical to STALE_AFTER_MS in web-dashboard/src/pages/DevicesPage.jsx --
    /// a parent checking both surfaces must not see them disagree.
    var isStale: Bool {
        guard let date = lastSeenDate else { return true }
        return Date().timeIntervalSince(date) > 15 * 60
    }

    var staleLabel: String {
        guard let date = lastSeenDate else { return "Never reported" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "Not reporting since \(f.string(from: date))"
    }
```

- [ ] **Step 2: Show it in the device list**

In `ParentApp/NesTimer/Views/DevicesListView.swift`, replace the trailing status `HStack` (around line 91-99) with a `VStack` that can carry the warning beneath it:

```swift
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(device.isOnline ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)

                    Text(device.isOnline ? "Online" : device.lastSeenText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if device.isStale {
                    Text(device.staleLabel)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                }
            }
```

- [ ] **Step 3: Show it on the detail screen**

In `ParentApp/NesTimer/Views/DeviceDetailView.swift`, immediately after the `infoRow(label: "Last Seen", ...)` call on line 379:

```swift
                    if device.isStale {
                        Label(device.staleLabel, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
```

- [ ] **Step 4: Build both platforms**

There is no test target in ParentApp; the build plus a visual check is the verification, as it is for every other change to this app.

```bash
cd /Users/ex/GitHub/Nestimer
xcodebuild -project ParentApp/NesTimer.xcodeproj -scheme NesTimer \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES build 2>&1 | tail -5

xcodebuild -project ParentApp/NesTimer.xcodeproj -scheme NesTimer \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` for both.

- [ ] **Step 5: Commit**

```bash
cd /Users/ex/GitHub/Nestimer
git add ParentApp
git commit -m "feat: surface quiet devices in the parent app"
```

---

### Task 8: On-device verification and the attach gate

Claude cannot do this task. It is written out so the steps are not improvised, and so the precondition is checked before the dangerous step rather than after.

**Files:** none.

- [ ] **Step 1: Install and pair**

```bash
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
"$ANDROID_HOME/platform-tools/adb" devices          # confirm the phone is listed
"$ANDROID_HOME/platform-tools/adb" install -r android-agent/app/build/outputs/apk/release/app-release.apk
```

In the parent app or the web dashboard, add a device for the child with `platform = android`, copy the `server|token` string, paste it into the phone, and grant all four items until the screen says "Reporting".

- [ ] **Step 2: Verify counting is real, not merely present**

Use two apps for a few minutes each, including switching between them. Then check the device in the dashboard: the minutes should be close to the time actually spent, and clearly not double it — that would mean the handoff union in `UsageCounter` is broken in a way the unit tests missed.

- [ ] **Step 3: Verify it survives a reboot**

Reboot the phone, wait two minutes, confirm the notification returns on its own and `last_seen` advances.

- [ ] **Step 4: Verify force-stop recovery — the core claim of the design**

Force-stop the app in Settings. Use the phone for ~10 minutes. Reopen NesTimer. The reported total must include those 10 minutes. If it does not, the counter is not actually stateless and the design's central claim is wrong.

- [ ] **Step 5: Verify the quiet warning appears**

While the app is force-stopped, wait 15 minutes and confirm both the web dashboard and the parent app show "Not reporting since HH:MM".

- [ ] **Step 6: THE GATE — check every Mac before attaching the phone to the child**

Do not skip and do not infer this from a successful deploy. Read it from the API:

```bash
# Log in and list devices; inspect agent_version and last_seen for EVERY device
# belonging to the child the phone will join.
curl -s https://my.nestimer.com/devices \
  -H "Authorization: Bearer <parent JWT>" | python3 -m json.tool
```

For each Mac under that child, require **both**:
- `agent_version` is `3.0` or later, and
- `last_seen` is within the last few minutes.

An agent still on 2.9 echoes the child's combined total back as its own, and the server
clamp keeps that linear rather than exponential — but on a child with two devices it
still burns a 120-minute budget in roughly 15–20 real minutes and locks the child out.

- [ ] **Step 7: Attach, or don't**

- **All Macs pass:** assign the phone to the child. Phone time now drains the shared budget and the Mac locks sooner.
- **Any Mac fails:** leave the phone on its own `Child`. It still counts correctly and still shows up in the dashboard; it just does not share a budget yet. Update the Mac, re-check Step 6, then attach.

- [ ] **Step 8: Watch the first full day**

Check once in the evening that the child's total looks like the sum of both devices and that neither counter has run away. The clamp logs a warning on every rejected report:

```bash
ssh root@134.209.8.62 "cd ~/Nestimer && docker compose logs api --since 24h | grep -i 'Clamped usage report'"
```

Expected: no output. Any line here means some device is reporting time it cannot have accumulated.
