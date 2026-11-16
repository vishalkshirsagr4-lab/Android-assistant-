package com.poc.screen_aware_ai

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.provider.CalendarContract
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONArray
import java.util.Calendar
import java.util.concurrent.TimeUnit

/** Local-only proactive evaluation. It never calls an AI provider or performs phone actions. */
class ProactiveSuggestionWorker(appContext: Context, params: WorkerParameters) :
    Worker(appContext, params) {

    override fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return Result.success()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(applicationContext, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return Result.success()

        val now = System.currentTimeMillis()
        val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        if (isQuietHour(hour, prefs.getInt(KEY_QUIET_START, 22), prefs.getInt(KEY_QUIET_END, 8))) {
            return Result.success()
        }

        val calendar = Calendar.getInstance()
        val today = calendar.get(Calendar.YEAR) * 1000 + calendar.get(Calendar.DAY_OF_YEAR)
        val storedDay = prefs.getInt(KEY_DAY, -1)
        val count = if (storedDay == today) prefs.getInt(KEY_DAILY_COUNT, 0) else 0
        if (count >= prefs.getInt(KEY_DAILY_LIMIT, 3).coerceIn(1, 10)) return Result.success()

        val lastAt = prefs.getLong(KEY_LAST_AT, 0L)
        val cooldown = prefs.getInt(KEY_COOLDOWN_MINUTES, 120).coerceIn(15, 1440)
        if (lastAt > 0L && now - lastAt < TimeUnit.MINUTES.toMillis(cooldown.toLong())) {
            return Result.success()
        }

        val decision = evaluate(now, prefs) ?: return Result.success()
        postSuggestion(decision)
        prefs.edit()
            .putLong(KEY_LAST_AT, now)
            .putInt(KEY_DAY, today)
            .putInt(KEY_DAILY_COUNT, count + 1)
            .putString(KEY_LAST_TITLE, decision.title)
            .putString(KEY_LAST_SUGGESTION, decision.message)
            .putString(KEY_LAST_REASON, decision.reason)
            .putString(KEY_LAST_RISK, decision.risk)
            .putFloat(KEY_LAST_CONFIDENCE, decision.confidence)
            .apply()
        return Result.success()
    }

    private data class Decision(
        val title: String,
        val message: String,
        val reason: String,
        val confidence: Float,
        val risk: String = "low"
    )

    private fun evaluate(now: Long, prefs: android.content.SharedPreferences): Decision? {
        val batteryIntent = applicationContext.registerReceiver(
            null,
            android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        )
        val level = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val battery = if (level >= 0 && scale > 0) level * 100 / scale else -1
        val status = batteryIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        if (battery in 0..19 && !charging) {
            return Decision(
                "Battery is low",
                "Battery is at $battery%. Want to review Battery Saver settings?",
                "The battery is below 20% and the phone is not charging.",
                0.96f
            )
        }

        val event = findUpcomingEvent(now)
        if (event != null) {
            return Decision(
                "Upcoming calendar event",
                "An event is coming up: $event. Want to review your calendar?",
                "A calendar event starts within the next 30 minutes.",
                0.88f
            )
        }

        if (prefs.getBoolean(KEY_NOTIFICATION_CONTEXT, false) && findRecentNotification(now)) {
            return Decision(
                "New notification",
                "A new notification arrived. Want to review it?",
                "A notification arrived recently and notification suggestions are enabled.",
                0.74f
            )
        }
        return null
    }

    private fun findUpcomingEvent(now: Long): String? {
        if (ContextCompat.checkSelfPermission(
                applicationContext, Manifest.permission.READ_CALENDAR
            ) != PackageManager.PERMISSION_GRANTED
        ) return null

        val end = now + TimeUnit.MINUTES.toMillis(30)
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
            .appendPath(now.toString())
            .appendPath(end.toString())
            .build()
        val projection = arrayOf(CalendarContract.Instances.TITLE, CalendarContract.Instances.BEGIN)
        return try {
            applicationContext.contentResolver.query(
                uri, projection, null, null, CalendarContract.Instances.BEGIN + " ASC"
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Instances.TITLE))
                        ?.take(70)?.takeIf { it.isNotBlank() }
                } else null
            }
        } catch (_: SecurityException) {
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun findRecentNotification(now: Long): Boolean {
        val prefs = applicationContext.getSharedPreferences("lucy_context_store", Context.MODE_PRIVATE)
        return try {
            val entries = JSONArray(prefs.getString("recent_notifications", "[]") ?: "[]")
            val cutoff = now - TimeUnit.MINUTES.toMillis(15)
            (0 until entries.length()).any { index ->
                val item = entries.optJSONObject(index)
                item != null && item.optLong("timestamp", 0L) >= cutoff
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun postSuggestion(decision: Decision) {
        val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Lucy proactive suggestions", NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "Optional local suggestions. Lucy does not perform actions automatically."
                }
            )
        }
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(decision.title)
            .setContentText(decision.message)
            .setStyle(NotificationCompat.BigTextStyle().bigText(decision.message + "\nWhy: " + decision.reason))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }

    private fun isQuietHour(hour: Int, start: Int, end: Int): Boolean {
        val safeStart = start.coerceIn(0, 23)
        val safeEnd = end.coerceIn(0, 23)
        if (safeStart == safeEnd) return false
        return if (safeStart < safeEnd) hour >= safeStart && hour < safeEnd
        else hour >= safeStart || hour < safeEnd
    }

    companion object {
        const val PREFS = "lucy_proactive_settings"
        const val KEY_ENABLED = "enabled"
        const val KEY_QUIET_START = "quiet_start"
        const val KEY_QUIET_END = "quiet_end"
        const val KEY_DAILY_LIMIT = "daily_limit"
        const val KEY_COOLDOWN_MINUTES = "cooldown_minutes"
        const val KEY_NOTIFICATION_CONTEXT = "notification_context_enabled"
        const val KEY_DAY = "daily_count_day"
        const val KEY_DAILY_COUNT = "daily_count"
        const val KEY_LAST_AT = "last_suggestion_at"
        const val KEY_LAST_TITLE = "last_suggestion_title"
        const val KEY_LAST_SUGGESTION = "last_suggestion_message"
        const val KEY_LAST_REASON = "last_suggestion_reason"
        const val KEY_LAST_RISK = "last_suggestion_risk"
        const val KEY_LAST_CONFIDENCE = "last_suggestion_confidence"
        private const val CHANNEL_ID = "lucy_proactive_suggestions"
        private const val NOTIFICATION_ID = 9107
    }
}
