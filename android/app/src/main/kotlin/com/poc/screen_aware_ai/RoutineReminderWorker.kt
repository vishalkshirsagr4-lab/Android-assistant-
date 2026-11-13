package com.poc.screen_aware_ai

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.Worker
import androidx.work.WorkerParameters

/** A deliberately limited routine action: show a local reminder notification. */
class RoutineReminderWorker(appContext: Context, params: WorkerParameters) :
    Worker(appContext, params) {
    companion object {
        const val KEY_ID = "routine_id"
        const val KEY_TITLE = "routine_title"
        const val KEY_BODY = "routine_body"
        const val KEY_REPEAT_MINUTES = "repeat_minutes"
        const val KEY_BOOTSTRAP_REPEAT = "bootstrap_repeat"
        private const val CHANNEL_ID = "lucy_routine_reminders"
    }

    override fun doWork(): Result {
        val id = inputData.getString(KEY_ID) ?: return Result.failure()
        val title = inputData.getString(KEY_TITLE)?.take(80)?.takeIf { it.isNotBlank() }
            ?: return Result.failure()
        val body = inputData.getString(KEY_BODY)?.take(240).orEmpty()
        val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(
                CHANNEL_ID, "Lucy routine reminders", NotificationManager.IMPORTANCE_DEFAULT
            ).apply { description = "Notifications from routines scheduled in Lucy." })
        }
        val message = body.ifBlank { "Your scheduled Lucy routine is ready." }
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(message)
            .setStyle(NotificationCompat.BigTextStyle().bigText(message))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        manager.notify(id.hashCode(), notification)

        // The first delayed one-time run installs the recurring request.
        // PeriodicWorkRequest itself cannot carry an initial delay.
        val repeatMinutes = inputData.getInt(KEY_REPEAT_MINUTES, 0)
        val bootstrapRepeat = inputData.getBoolean(KEY_BOOTSTRAP_REPEAT, false)
        if (bootstrapRepeat && repeatMinutes >= 15) {
            val periodicInput = androidx.work.workDataOf(
                KEY_ID to id,
                KEY_TITLE to title,
                KEY_BODY to body,
                KEY_REPEAT_MINUTES to 0,
                KEY_BOOTSTRAP_REPEAT to false
            )
            val periodic = androidx.work.PeriodicWorkRequestBuilder<RoutineReminderWorker>(
                repeatMinutes.toLong(), java.util.concurrent.TimeUnit.MINUTES
            ).setInputData(periodicInput)
                .addTag("lucy_routine")
                .addTag("routine_id:$id")
                .build()
            androidx.work.WorkManager.getInstance(applicationContext)
                .enqueueUniquePeriodicWork(
                    "$id-periodic",
                    androidx.work.ExistingPeriodicWorkPolicy.UPDATE,
                    periodic
                )
        }
        return Result.success()
    }
}
