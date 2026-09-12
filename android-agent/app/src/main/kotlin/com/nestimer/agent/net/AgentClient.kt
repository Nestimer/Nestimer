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
