package com.poc.screen_aware_ai

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject

/**
 * Stores a short, bounded notification history locally.
 *
 * Android binds this service only after the user explicitly enables Lucy in
 * Notification access settings. Notification contents are never logged.
 */
class NotificationContextListener : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null || sbn.packageName == packageName) return
        val preferences = getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
        if (!preferences.getBoolean(NOTIFICATION_ENABLED_KEY, false)) return
        val notification = sbn.notification ?: return
        if (notification.flags and Notification.FLAG_ONGOING_EVENT != 0) return

        val extras = notification.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val body = (
            extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
                ?: extras.getCharSequence(Notification.EXTRA_TEXT)
                ?: extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT)
            )?.toString().orEmpty()
        val sender = (
            extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)
                ?: extras.getCharSequence(Notification.EXTRA_SUB_TEXT)
            )?.toString().orEmpty()

        if (title.isBlank() && body.isBlank()) return

        val appLabel = try {
            packageManager.getApplicationLabel(
                packageManager.getApplicationInfo(sbn.packageName, 0)
            ).toString()
        } catch (_: Exception) {
            sbn.packageName
        }

        val entry = JSONObject().apply {
            put("app", appLabel.take(60))
            put("package", sbn.packageName.take(120))
            put("sender", redact(sender).take(80))
            put("title", redact(title).take(120))
            put("text", redact(body).take(240))
            put("timestamp", sbn.postTime)
        }
        appendEntry(entry)
    }

    private fun appendEntry(entry: JSONObject) {
        synchronized(STORE_LOCK) {
            val preferences = getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
            val previous = try {
                JSONArray(preferences.getString(NOTIFICATION_KEY, "[]") ?: "[]")
            } catch (_: Exception) {
                JSONArray()
            }
            val updated = JSONArray()
            val start = (previous.length() - MAX_ENTRIES + 1).coerceAtLeast(0)
            for (index in start until previous.length()) {
                // Ignore malformed legacy entries rather than crashing the
                // notification listener while it is running in the background.
                previous.optJSONObject(index)?.let { item -> updated.put(item) }
            }
            updated.put(entry)
            preferences.edit().putString(NOTIFICATION_KEY, updated.toString()).apply()
        }
    }

    private fun redact(value: String): String {
        val otpPattern = Regex(
            "(?i)(\\b(?:otp|one[- ]time password|verification code|passcode)\\b\\s*[:is-]*\\s*)\\d{4,8}"
        )
        return value
            .let { source ->
                otpPattern.replace(source) { match ->
                    match.groupValues[1] + "[hidden]"
                }
            }
            .replace(Regex("(?i)\\b[\\w.+-]+@[\\w.-]+\\.[a-z]{2,}\\b"), "[email hidden]")
            .replace(Regex("(?<!\\d)(?:\\+?\\d[\\d .()-]{7,}\\d)(?!\\d)"), "[phone/number hidden]")
            .replace(Regex("\\b\\d{4,8}\\b"), "[number hidden]")
    }

    companion object {
        const val PREFERENCES_NAME = "lucy_context_store"
        const val NOTIFICATION_KEY = "recent_notifications"
        const val NOTIFICATION_ENABLED_KEY = "notification_context_enabled"
        const val LOCATION_ENABLED_KEY = "approximate_location_enabled"
        const val MAX_ENTRIES = 20
        private val STORE_LOCK = Any()
    }
}
