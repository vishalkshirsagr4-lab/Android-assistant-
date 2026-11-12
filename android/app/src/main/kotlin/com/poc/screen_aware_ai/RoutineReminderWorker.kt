package com.poc.screen_aware_ai

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.Worker
import androidx.work.WorkerParameters

/**
 * A deliberately limited routine action: show a local reminder notification.
 * It never performs screen taps, sends messages, purchases, or changes settings.
 */
class RoutineReminderWorker(
    appContext: Context,
    params: WorkerParameters,
) : Worker(appContext, params) {
    companion object {
        const val KEY_ID = "routine_id"
        const val KEY_TITLE = "routine_title"
        const val KEY_BODY = "routine_body"
        private const val CHANNEL_ID = "lucy_routine_reminders"
    }

    override fun doWork(): Result {
        val id = inputData.getString(KEY_ID) ?: return Result.failure()
        val title = inputData.getString(KEY_TITLE)?.take(80)?.takeIf { it.isNotBlank() }
            ?: return Result.failure()
        val body = inputData.getString(KEY_BODY)?.take(240).orEmpty()
        val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Lucy routine reminders",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "Notifications from routines you scheduled in Lucy."
                },
            )
        }

        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body.ifBlank { "Your scheduled Lucy routine is ready." })
            .setStyle(NotificationCompat.BigTextStyle().bigText(body.ifBlank { "Your scheduled Lucy routine is ready." }))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        manager.notify(id.hashCode(), notification)
        return Result.success()
    }
}
