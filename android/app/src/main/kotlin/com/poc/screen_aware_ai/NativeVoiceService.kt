package com.poc.screen_aware_ai

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log

/** User-started microphone service with a visible notification and Stop action. */
class NativeVoiceService : Service() {
    companion object {
        const val ACTION_FORCE_STOP = "com.poc.screen_aware_ai.NATIVE_VOICE_STOPPED"
        const val ACTION_RESULT = "com.poc.screen_aware_ai.NATIVE_VOICE_RESULT"
        const val ACTION_ERROR = "com.poc.screen_aware_ai.NATIVE_VOICE_ERROR"
        const val EXTRA_LOCALE = "localeId"
        private const val ACTION_STOP = "com.poc.screen_aware_ai.STOP_NATIVE_VOICE"
        private const val CHANNEL_ID = "lucy_native_voice"
        private const val NOTIFICATION_ID = 2301
        private const val TAG = "NativeVoiceService"
    }

    private val handler = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var localeId = "en_US"
    private var stopped = false
    private var restartScheduled = false
    private var retryMs = 1000L

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Lucy microphone", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopByUser()
            return START_NOT_STICKY
        }
        stopped = false
        localeId = intent?.getStringExtra(EXTRA_LOCALE) ?: localeId
        try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            startRecognition()
        } catch (error: Exception) {
            Log.e(TAG, "Could not start voice foreground service", error)
            emitError(error.message ?: "Could not start microphone service")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startRecognition() {
        if (stopped || restartScheduled) return
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            emitError("Android speech recognition service is unavailable.")
            stopSelf()
            return
        }
        try {
            recognizer?.destroy()
            recognizer = SpeechRecognizer.createSpeechRecognizer(this).also { engine ->
                engine.setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(params: android.os.Bundle?) { retryMs = 1000L }
                    override fun onBeginningOfSpeech() {}
                    override fun onRmsChanged(rmsdB: Float) {}
                    override fun onBufferReceived(buffer: ByteArray?) {}
                    override fun onEndOfSpeech() {}
                    override fun onEvent(eventType: Int, params: android.os.Bundle?) {}
                    override fun onPartialResults(results: android.os.Bundle?) { publish(results, false) }
                    override fun onResults(results: android.os.Bundle?) {
                        publish(results, true)
                        scheduleRestart(350L)
                    }
                    override fun onError(error: Int) {
                        if (stopped) return
                        if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS) {
                            emitError("Microphone permission is missing.")
                            stopSelf()
                        } else {
                            // SpeechRecognizer commonly ends an utterance with
                            // ERROR_SPEECH_TIMEOUT. This is recoverable: retry
                            // inside the foreground service only. Do not also
                            // ask Flutter to restart, which caused competing
                            // recognizers and repeated listening-timeout loops.
                            Log.w(TAG, "Recoverable speech interruption (code $error); reconnecting")
                            scheduleRestart(retryMs)
                        }
                    }
                })
                val request = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, localeId.replace('_', '-'))
                    putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                    putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                    putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName)
                }
                engine.startListening(request)
            }
        } catch (error: Exception) {
            emitError(error.message ?: "Speech recognition failed")
            scheduleRestart(retryMs)
        }
    }

    private fun publish(bundle: android.os.Bundle?, final: Boolean) {
        val words = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: return
        sendBroadcast(Intent(ACTION_RESULT).setPackage(packageName).apply {
            putExtra("text", words)
            putExtra("isFinal", final)
        })
    }

    private fun emitError(message: String) {
        sendBroadcast(Intent(ACTION_ERROR).setPackage(packageName).putExtra("message", message))
    }

    private fun scheduleRestart(delay: Long) {
        if (stopped || restartScheduled) return
        restartScheduled = true
        handler.postDelayed({
            restartScheduled = false
            if (!stopped) startRecognition()
        }, delay)
        retryMs = (retryMs * 2).coerceAtMost(30000L)
    }

    private fun stopByUser() {
        stopped = true
        handler.removeCallbacksAndMessages(null)
        try { recognizer?.cancel() } catch (_: Exception) {}
        recognizer?.destroy()
        recognizer = null
        sendBroadcast(Intent(ACTION_FORCE_STOP).setPackage(packageName))
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun buildNotification(): Notification {
        val stopIntent = Intent(this, NativeVoiceService::class.java).setAction(ACTION_STOP)
        val stopAction = PendingIntent.getService(this, NOTIFICATION_ID, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder.setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Lucy is listening")
            .setContentText("Microphone active · Tap Stop to end listening")
            .setOngoing(true)
            .addAction(Notification.Action.Builder(android.R.drawable.ic_media_pause, "Stop Lucy", stopAction).build())
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopped = true
        handler.removeCallbacksAndMessages(null)
        try { recognizer?.cancel() } catch (_: Exception) {}
        recognizer?.destroy()
        recognizer = null
        super.onDestroy()
    }
}
