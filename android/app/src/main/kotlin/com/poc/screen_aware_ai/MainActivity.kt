package com.poc.screen_aware_ai

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.poc.screen_aware_ai/screen"
    private val SCREEN_CAPTURE_REQUEST_CODE = 1001
    private val TAG = "MainActivity"

    private var pendingResult: MethodChannel.Result? = null
    private var mediaProjectionManager: MediaProjectionManager? = null
    private var methodChannel: MethodChannel? = null
    private var voiceChannel: MethodChannel? = null
    private var lastMetricsElapsedMs: Long? = null
    private var lastMetricsCpuMs: Long? = null
    private var pendingPhonePermissionResult: MethodChannel.Result? = null

    companion object {
        private const val PHONE_PERMISSION_REQUEST_CODE = 4402
    }

    // Store projection data so we can reinitialize the service if needed.
    // IMPORTANT: Use 0 as sentinel — Activity.RESULT_OK is -1, so -1 can't be the default.
    private var projectionResultCode: Int = 0
    private var projectionData: Intent? = null

    // Broadcast receiver for the stop notification action
    private val forceStopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                OverlayService.ACTION_FORCE_STOP, NativeVoiceService.ACTION_FORCE_STOP -> {
                    Log.d(TAG, "Received voice Stop broadcast")
                    methodChannel?.invokeMethod("onForceStop", null)
                }
                NativeVoiceService.ACTION_RESULT -> voiceChannel?.invokeMethod("onResult",
                    mapOf("text" to intent.getStringExtra("text").orEmpty(),
                          "isFinal" to intent.getBooleanExtra("isFinal", false)))
                NativeVoiceService.ACTION_ERROR -> voiceChannel?.invokeMethod("onError",
                    mapOf("message" to intent.getStringExtra("message").orEmpty()))
                NativeVoiceService.ACTION_STOPPED -> voiceChannel?.invokeMethod(
                    "onStopped", mapOf("userInitiated" to intent.getBooleanExtra("userInitiated", false))
                )
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        mediaProjectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

        // Register broadcast receiver for the stop notification action
        val filter = IntentFilter(OverlayService.ACTION_FORCE_STOP).apply {
            addAction(NativeVoiceService.ACTION_FORCE_STOP)
            addAction(NativeVoiceService.ACTION_RESULT)
            addAction(NativeVoiceService.ACTION_ERROR)
            addAction(NativeVoiceService.ACTION_STOPPED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(forceStopReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(forceStopReceiver, filter)
        }

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel

        val voice = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.poc.screen_aware_ai/voice")
        voiceChannel = voice
        voice.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (androidx.core.content.ContextCompat.checkSelfPermission(
                            this, android.Manifest.permission.RECORD_AUDIO
                        ) != android.content.pm.PackageManager.PERMISSION_GRANTED
                    ) {
                        result.error("MIC_PERMISSION", "Microphone permission is required.", null)
                    } else {
                        try {
                            val serviceIntent = Intent(this, NativeVoiceService::class.java).apply {
                                putExtra(NativeVoiceService.EXTRA_LOCALE, call.argument<String>("localeId") ?: "en_US")
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(serviceIntent)
                            else startService(serviceIntent)
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("VOICE_START_FAILED", error.message, null)
                        }
                    }
                }
                "stop" -> {
                    stopService(Intent(this, NativeVoiceService::class.java))
                    result.success(true)
                }
                "updateStatus" -> {
                    val status = call.argument<String>("status")
                        ?.replace(Regex("\\s+"), " ")
                        ?.take(120)
                        ?.ifBlank { "Lucy is working" }
                        ?: "Lucy is working"
                    NativeVoiceService.updateStatus(status)
                    result.success(true)
                }
                "pauseForProcessing" -> {
                    NativeVoiceService.pauseForProcessing()
                    result.success(true)
                }
                "resumeAfterProcessing" -> {
                    NativeVoiceService.resumeAfterProcessing()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Native phone actions use Android intents and APIs instead of UI tapping.
        val phoneActionHandler = PhoneActionHandler(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.poc.screen_aware_ai/phone_actions"
        ).setMethodCallHandler { call, result ->
            if (call.method == "requestPermission") {
                val permission = call.argument<String>("permission")
                val allowedPermissions = setOf(
                    android.Manifest.permission.READ_CONTACTS,
                    android.Manifest.permission.CAMERA,
                    android.Manifest.permission.READ_CALENDAR,
                    android.Manifest.permission.ACCESS_COARSE_LOCATION
                )
                if (permission == null || permission !in allowedPermissions) {
                    result.error("INVALID_PERMISSION", "This permission cannot be requested by Lucy.", null)
                } else if (androidx.core.content.ContextCompat.checkSelfPermission(
                        this, permission
                    ) == android.content.pm.PackageManager.PERMISSION_GRANTED
                ) {
                    result.success(true)
                } else if (pendingPhonePermissionResult != null) {
                    result.error("PERMISSION_REQUEST_BUSY", "Another phone permission request is active.", null)
                } else {
                    pendingPhonePermissionResult = result
                    requestPermissions(arrayOf(permission), PHONE_PERMISSION_REQUEST_CODE)
                }
            } else if (!phoneActionHandler.handle(call, result)) {
                result.notImplemented()
            }
        }

        // Context is fetched on demand for each AI request. No background polling.
        val contextHandler = PhoneContextHandler(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.poc.screen_aware_ai/context"
        ).setMethodCallHandler { call, result ->
            if (call.method == "requestPermission") {
                val permission = call.argument<String>("permission")
                val allowedPermissions = setOf(
                    android.Manifest.permission.READ_CALENDAR,
                    android.Manifest.permission.ACCESS_COARSE_LOCATION
                )
                if (permission == null || permission !in allowedPermissions) {
                    result.error("INVALID_PERMISSION", "This context permission cannot be requested by Lucy.", null)
                } else if (androidx.core.content.ContextCompat.checkSelfPermission(
                        this, permission
                    ) == android.content.pm.PackageManager.PERMISSION_GRANTED
                ) {
                    result.success(true)
                } else if (pendingPhonePermissionResult != null) {
                    result.error("PERMISSION_REQUEST_BUSY", "Another permission request is active.", null)
                } else {
                    pendingPhonePermissionResult = result
                    requestPermissions(arrayOf(permission), PHONE_PERMISSION_REQUEST_CODE)
                }
            } else if (!contextHandler.handle(call, result)) {
                result.notImplemented()
            }
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestScreenCapture" -> {
                    pendingResult = result
                    val intent = mediaProjectionManager!!.createScreenCaptureIntent()
                    startActivityForResult(intent, SCREEN_CAPTURE_REQUEST_CODE)
                }
                "captureScreen" -> {
                    val service = ScreenCaptureService.instance
                    if (service == null) {
                        // Service not running at all — try to restart if we have stored data
                        if (projectionResultCode == Activity.RESULT_OK && projectionData != null) {
                            Log.w(TAG, "captureScreen: service is null, restarting with stored projection data")
                            try {
                                startCaptureService(projectionResultCode, projectionData!!)
                                // Return error so Flutter side can retry after service starts
                                result.error("NOT_INITIALIZED", "Service restarting, retry capture", null)
                            } catch (e: Exception) {
                                // On Android 14+ the token may be single-use — need fresh permission
                                Log.e(TAG, "captureScreen: failed to restart service with stored data", e)
                                projectionData = null
                                result.error("NO_SERVICE", "Screen capture token expired, need new permission", null)
                            }
                        } else {
                            result.error("NO_SERVICE", "Screen capture service not running, need permission", null)
                        }
                    } else if (!service.isInitialized) {
                        // Service exists but imageReader is null — try to reinitialize
                        if (projectionResultCode == Activity.RESULT_OK && projectionData != null) {
                            Log.w(TAG, "captureScreen: service not initialized, reinitializing with stored data")
                            try {
                                service.initializeProjection(projectionResultCode, projectionData!!)
                                // If initialization succeeded, capture immediately
                                if (service.isInitialized) {
                                    service.captureScreen { bytes ->
                                        runOnUiThread { result.success(bytes) }
                                    }
                                } else {
                                    result.error("NOT_INITIALIZED", "Failed to reinitialize, need new permission", null)
                                }
                            } catch (e: SecurityException) {
                                // Android 14+: projection token is single-use, can't be reused
                                Log.e(TAG, "captureScreen: SecurityException — token expired, need new permission", e)
                                projectionData = null
                                result.error("NOT_INITIALIZED", "Projection token expired, need new permission", null)
                            } catch (e: Exception) {
                                Log.e(TAG, "captureScreen: reinit failed", e)
                                result.error("NOT_INITIALIZED", "Reinit failed: ${e.message}", null)
                            }
                        } else {
                            result.error("NOT_INITIALIZED", "Service not initialized, need permission", null)
                        }
                    } else {
                        service.captureScreen { bytes ->
                            runOnUiThread { result.success(bytes) }
                        }
                    }
                }
                "isAccessibilityEnabled" -> {
                    result.success(ScreenActionService.instance != null)
                }
                "isDeviceLocked" -> {
                    val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
                    result.success(keyguard.isKeyguardLocked)
                }
                "getDeviceMetrics" -> {
                    val nowElapsed = android.os.SystemClock.elapsedRealtime()
                    val nowCpu = android.os.Process.getElapsedCpuTime()
                    val previousElapsed = lastMetricsElapsedMs
                    val previousCpu = lastMetricsCpuMs
                    lastMetricsElapsedMs = nowElapsed
                    lastMetricsCpuMs = nowCpu
                    val cpuPercent = if (previousElapsed != null && previousCpu != null && nowElapsed > previousElapsed) {
                        (((nowCpu - previousCpu).toDouble() / (nowElapsed - previousElapsed)) * 100.0)
                            .coerceIn(0.0, 100.0)
                    } else null
                    val batteryManager = getSystemService(Context.BATTERY_SERVICE) as android.os.BatteryManager
                    val battery = batteryManager.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
                    result.success(mapOf(
                        "cpuPercent" to cpuPercent,
                        "batteryPercent" to if (battery in 0..100) battery else null
                    ))
                }
                "getScreenSize" -> {
                    val service = ScreenCaptureService.instance
                    if (service != null) {
                        result.success(mapOf("width" to service.screenWidth, "height" to service.screenHeight))
                    } else {
                        val wm = getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
                        val metrics = android.util.DisplayMetrics()
                        @Suppress("DEPRECATION")
                        wm.defaultDisplay.getRealMetrics(metrics)
                        result.success(mapOf("width" to metrics.widthPixels, "height" to metrics.heightPixels))
                    }
                }
                "performTap" -> {
                    val x = call.argument<Double>("x")?.toFloat() ?: 0f
                    val y = call.argument<Double>("y")?.toFloat() ?: 0f
                    val service = ScreenActionService.instance
                    if (service != null) {
                        Thread {
                            val success = service.performTap(x, y)
                            runOnUiThread { result.success(success) }
                        }.start()
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "performType" -> {
                    val text = call.argument<String>("text") ?: ""
                    val service = ScreenActionService.instance
                    if (service != null) {
                        result.success(service.performType(text))
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "pressBack" -> {
                    val service = ScreenActionService.instance
                    if (service != null) {
                        result.success(service.pressBack())
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "pressHome" -> {
                    val service = ScreenActionService.instance
                    if (service != null) {
                        result.success(service.pressHome())
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "openApp" -> {
                    val packageName = call.argument<String>("packageName") ?: ""
                    try {
                        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
                        if (keyguard.isKeyguardLocked) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                        if (launchIntent != null) {
                            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(launchIntent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.error("LAUNCH_FAILED", "Could not launch $packageName: ${e.message}", null)
                    }
                }
                "performSwipe" -> {
                    val startX = call.argument<Double>("startX")?.toFloat() ?: 0f
                    val startY = call.argument<Double>("startY")?.toFloat() ?: 0f
                    val endX = call.argument<Double>("endX")?.toFloat() ?: 0f
                    val endY = call.argument<Double>("endY")?.toFloat() ?: 0f
                    val service = ScreenActionService.instance
                    if (service != null) {
                        Thread {
                            val success = service.performSwipe(startX, startY, endX, endY)
                            runOnUiThread { result.success(success) }
                        }.start()
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "keepScreenAwake" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val service = ScreenActionService.instance
                    if (service != null) {
                        result.success(service.keepScreenAwake(enabled))
                    } else {
                        result.success(false)
                    }
                }
                "configureScreenWatcher" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    val skipAds = call.argument<Boolean>("skipAds") ?: true
                    val dismissPopups = call.argument<Boolean>("dismissPopups") ?: true
                    val excludedPackages = call.argument<List<String>>("excludedPackages")?.toSet() ?: emptySet()
                    val service = ScreenActionService.instance
                    result.success(
                        service?.configureScreenWatcher(
                            enabled,
                            skipAds,
                            dismissPopups,
                            excludedPackages
                        ) ?: false
                    )
                }
                "cancelScreenOperation" -> {
                    result.success(ScreenActionService.instance?.cancelScreenOperation() ?: false)
                }
                "scrollScreen" -> {
                    val forward = call.argument<Boolean>("forward") ?: true
                    val maxScrolls = call.argument<Int>("maxScrolls") ?: 80
                    val collect = call.argument<Boolean>("collect") ?: false
                    val service = ScreenActionService.instance
                    if (service != null) {
                        val operationId = service.beginScrollOperation()
                        Thread {
                            val payload = try {
                                service.scrollScreen(forward, maxScrolls, collect, operationId)
                            } catch (error: Exception) {
                                Log.e(TAG, "Native deep scroll failed", error)
                                org.json.JSONObject().apply {
                                    put("scrolls", 0)
                                    put("reachedEnd", false)
                                    put("limited", false)
                                    put("dispatchFailed", true)
                                    put("error", error.javaClass.simpleName)
                                    put("items", org.json.JSONArray())
                                }.toString()
                            }
                            runOnUiThread { result.success(payload) }
                        }.start()
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "performBatch" -> {
                    val actions = call.argument<List<Map<String, Any?>>>("actions") ?: emptyList()
                    val service = ScreenActionService.instance
                    if (service != null) {
                        Thread {
                            val payload = try {
                                service.performBatch(org.json.JSONArray(actions).toString())
                            } catch (error: Exception) {
                                Log.e(TAG, "Native batch execution failed", error)
                                org.json.JSONObject().apply {
                                    put("success", false)
                                    put("error", error.javaClass.simpleName)
                                    put("completed", 0)
                                    put("results", org.json.JSONArray())
                                }.toString()
                            }
                            runOnUiThread { result.success(payload) }
                        }.start()
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "getUiEventSequence" -> {
                    val service = ScreenActionService.instance
                    result.success(service?.getUiEventSequence() ?: 0L)
                }
                "waitForUiEvent" -> {
                    val afterSequence = call.argument<Number>("afterSequence")?.toLong() ?: 0L
                    val timeoutMs = call.argument<Int>("timeoutMs") ?: 500
                    val service = ScreenActionService.instance
                    if (service != null) {
                        Thread {
                            val sequence = service.waitForUiEvent(afterSequence, timeoutMs.toLong())
                            runOnUiThread { result.success(sequence) }
                        }.start()
                    } else {
                        result.success(afterSequence)
                    }
                }
                "getUITree" -> {
                    val service = ScreenActionService.instance
                    if (service != null) {
                        result.success(service.getUITree())
                    } else {
                        result.error("NO_SERVICE", "Accessibility service not enabled", null)
                    }
                }
                "openAccessibilitySettings" -> {
                    val intent = Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    startActivity(intent)
                    result.success(true)
                }
                "showStopOverlay" -> {
                    try {
                        val intent = Intent(this, OverlayService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    } catch (error: SecurityException) {
                        Log.e(TAG, "Microphone foreground service permission denied", error)
                        result.error("MICROPHONE_FGS_DENIED", "Android denied the microphone foreground service. Confirm microphone permission and start Lucy again.", null)
                    } catch (error: Exception) {
                        Log.e(TAG, "Could not start Lucy foreground service", error)
                        result.error("FGS_START_FAILED", error.message ?: "Could not start background service", null)
                    }
                }
                "hideStopOverlay" -> {
                    try {
                        val service = OverlayService.instance
                        if (service != null) service.hideOverlay()
                        stopService(Intent(this, OverlayService::class.java))
                        result.success(true)
                    } catch (error: Exception) {
                        Log.e(TAG, "Could not stop Lucy foreground service", error)
                        result.error("FGS_STOP_FAILED", error.message ?: "Could not stop background service", null)
                    }
                }
                else -> result.notImplemented()
            }
        }


        // Persistent routine scheduling. WorkManager restores scheduled work
        // after process death and reboot. Current routines are notification-only.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.poc.screen_aware_ai/routines")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensureNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            androidx.core.content.ContextCompat.checkSelfPermission(
                                this, android.Manifest.permission.POST_NOTIFICATIONS
                            ) != android.content.pm.PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 3301)
                            result.success(false)
                        } else {
                            result.success(true)
                        }
                    }
                    "scheduleReminder" -> {
                        val id = call.argument<String>("id")?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{1,64}")) }
                        val title = call.argument<String>("title")?.take(80)?.trim().orEmpty()
                        val body = call.argument<String>("body")?.take(240)?.trim().orEmpty()
                        val delayMinutes = call.argument<Int>("delayMinutes") ?: 0
                        val repeatMinutes = call.argument<Int>("repeatIntervalMinutes") ?: 0
                        if (id == null || title.isBlank() || delayMinutes !in 1..525600 ||
                            repeatMinutes < 0 || repeatMinutes > 525600 ||
                            (repeatMinutes in 1..14)) {
                            result.error("INVALID_ROUTINE", "Invalid reminder or repeat interval. Repeating routines must be at least 15 minutes apart.", null)
                        } else {
                            try {
                                val input = androidx.work.workDataOf(
                                    RoutineReminderWorker.KEY_ID to id,
                                    RoutineReminderWorker.KEY_TITLE to title,
                                    RoutineReminderWorker.KEY_BODY to body,
                                    RoutineReminderWorker.KEY_REPEAT_MINUTES to repeatMinutes,
                                    RoutineReminderWorker.KEY_BOOTSTRAP_REPEAT to (repeatMinutes >= 15)
                                )
                                val manager = androidx.work.WorkManager.getInstance(applicationContext)
                                // PeriodicWorkRequest does not support an initial delay.
                                // Run a delayed one-time bootstrap first; it posts the
                                // first reminder and then registers the periodic request.
                                val request = androidx.work.OneTimeWorkRequestBuilder<RoutineReminderWorker>()
                                    .setInitialDelay(delayMinutes.toLong(), java.util.concurrent.TimeUnit.MINUTES)
                                    .setInputData(input)
                                    .addTag("lucy_routine")
                                    .addTag("routine_id:$id")
                                    .build()
                                manager.enqueueUniqueWork(id, androidx.work.ExistingWorkPolicy.REPLACE, request)
                                result.success(true)
                            } catch (error: Exception) {
                                result.error("SCHEDULE_FAILED", error.message, null)
                            }
                        }
                    }
                    "listRoutines" -> {
                        val manager = androidx.work.WorkManager.getInstance(applicationContext)
                        manager.getWorkInfosByTag("lucy_routine").addListener({
                            try {
                                val routines = manager.getWorkInfosByTag("lucy_routine").get().map { info ->
                                    mapOf(
                                        "id" to (info.tags.firstOrNull { it.startsWith("routine_id:") }?.removePrefix("routine_id:") ?: info.id.toString()),
                                        "state" to info.state.name,
                                        "runAttemptCount" to info.runAttemptCount
                                    )
                                }
                                result.success(routines)
                            } catch (error: Exception) {
                                result.error("LIST_FAILED", error.message, null)
                            }
                        }, androidx.core.content.ContextCompat.getMainExecutor(this))
                    }
                    "cancelReminder" -> {
                        val id = call.argument<String>("id") ?: ""
                        if (!id.matches(Regex("[A-Za-z0-9_-]{1,64}"))) {
                            result.error("INVALID_ROUTINE", "Invalid routine id.", null)
                        } else {
                            val manager = androidx.work.WorkManager.getInstance(applicationContext)
                            manager.cancelUniqueWork(id)
                            manager.cancelUniqueWork("$id-periodic")
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Optional local proactive suggestions. Periodic evaluation is WorkManager-managed
        // (Android's minimum periodic interval is 15 minutes); it never runs phone actions.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.poc.screen_aware_ai/proactive")
            .setMethodCallHandler { call, result ->
                val preferences = getSharedPreferences(
                    ProactiveSuggestionWorker.PREFS,
                    Context.MODE_PRIVATE
                )
                when (call.method) {
                    "clearData" -> {
                        preferences.edit().clear().apply()
                        androidx.work.WorkManager.getInstance(applicationContext)
                            .cancelUniqueWork("lucy_proactive_evaluation")
                        result.success(true)
                    }
                    "configure" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        val quietStart = call.argument<Int>("quietStartHour") ?: 22
                        val quietEnd = call.argument<Int>("quietEndHour") ?: 8
                        val dailyLimit = call.argument<Int>("dailyLimit") ?: 3
                        val cooldown = call.argument<Int>("cooldownMinutes") ?: 120
                        if (quietStart !in 0..23 || quietEnd !in 0..23 ||
                            dailyLimit !in 1..10 || cooldown !in 15..1440
                        ) {
                            result.error("INVALID_SETTINGS", "Invalid proactive suggestion settings.", null)
                        } else if (enabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            androidx.core.content.ContextCompat.checkSelfPermission(
                                this, android.Manifest.permission.POST_NOTIFICATIONS
                            ) != android.content.pm.PackageManager.PERMISSION_GRANTED
                        ) {
                            result.success(false)
                        } else {
                            val notificationContextEnabled = getSharedPreferences(
                                NotificationContextListener.PREFERENCES_NAME,
                                Context.MODE_PRIVATE
                            ).getBoolean(NotificationContextListener.NOTIFICATION_ENABLED_KEY, false)
                            preferences.edit()
                                .putBoolean(ProactiveSuggestionWorker.KEY_ENABLED, enabled)
                                .putInt(ProactiveSuggestionWorker.KEY_QUIET_START, quietStart)
                                .putInt(ProactiveSuggestionWorker.KEY_QUIET_END, quietEnd)
                                .putInt(ProactiveSuggestionWorker.KEY_DAILY_LIMIT, dailyLimit)
                                .putInt(ProactiveSuggestionWorker.KEY_COOLDOWN_MINUTES, cooldown)
                                .putBoolean(ProactiveSuggestionWorker.KEY_NOTIFICATION_CONTEXT, notificationContextEnabled)
                                .apply()
                            val manager = androidx.work.WorkManager.getInstance(applicationContext)
                            if (enabled) {
                                val request = androidx.work.PeriodicWorkRequestBuilder<ProactiveSuggestionWorker>(
                                    15, java.util.concurrent.TimeUnit.MINUTES
                                ).addTag("lucy_proactive")
                                    .build()
                                manager.enqueueUniquePeriodicWork(
                                    "lucy_proactive_evaluation",
                                    androidx.work.ExistingPeriodicWorkPolicy.UPDATE,
                                    request
                                )
                            } else {
                                manager.cancelUniqueWork("lucy_proactive_evaluation")
                            }
                            result.success(true)
                        }
                    }
                    "status" -> {
                        result.success(mapOf(
                            "enabled" to preferences.getBoolean(ProactiveSuggestionWorker.KEY_ENABLED, false),
                            "quietStartHour" to preferences.getInt(ProactiveSuggestionWorker.KEY_QUIET_START, 22),
                            "quietEndHour" to preferences.getInt(ProactiveSuggestionWorker.KEY_QUIET_END, 8),
                            "dailyLimit" to preferences.getInt(ProactiveSuggestionWorker.KEY_DAILY_LIMIT, 3),
                            "cooldownMinutes" to preferences.getInt(ProactiveSuggestionWorker.KEY_COOLDOWN_MINUTES, 120),
                            "lastSuggestion" to preferences.getString(ProactiveSuggestionWorker.KEY_LAST_TITLE, null),
                            "lastReason" to preferences.getString(ProactiveSuggestionWorker.KEY_LAST_REASON, null),
                            "lastRisk" to preferences.getString(ProactiveSuggestionWorker.KEY_LAST_RISK, null),
                            "lastConfidence" to preferences.getFloat(ProactiveSuggestionWorker.KEY_LAST_CONFIDENCE, -1f).takeIf { it >= 0f },
                            "lastSuggestionAt" to preferences.getLong(ProactiveSuggestionWorker.KEY_LAST_AT, 0L)
                        ))
                    }
                    "explain" -> {
                        result.success(mapOf(
                            "suggestion" to preferences.getString(ProactiveSuggestionWorker.KEY_LAST_SUGGESTION, null),
                            "reason" to preferences.getString(ProactiveSuggestionWorker.KEY_LAST_REASON, null),
                            "risk" to preferences.getString(ProactiveSuggestionWorker.KEY_LAST_RISK, null),
                            "confidence" to preferences.getFloat(ProactiveSuggestionWorker.KEY_LAST_CONFIDENCE, -1f).takeIf { it >= 0f }
                        ))
                    }
                    "runEvaluationNow" -> {
                        if (!preferences.getBoolean(ProactiveSuggestionWorker.KEY_ENABLED, false)) {
                            result.error("DISABLED", "Enable proactive suggestions first.", null)
                        } else {
                            val request = androidx.work.OneTimeWorkRequestBuilder<ProactiveSuggestionWorker>()
                                .addTag("lucy_proactive_manual_test")
                                .build()
                            androidx.work.WorkManager.getInstance(applicationContext)
                                .enqueue(request)
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Separate channel for safe, user-confirmed APK updates from GitHub Releases.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.poc.screen_aware_ai/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInstalledVersion" -> {
                        @Suppress("DEPRECATION")
                        val installed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            packageManager.getPackageInfo(
                                packageName,
                                android.content.pm.PackageManager.PackageInfoFlags.of(0)
                            )
                        } else {
                            packageManager.getPackageInfo(packageName, 0)
                        }
                        result.success(mapOf("versionName" to (installed.versionName ?: "0.0.0")))
                    }
                    "canInstallPackages" -> {
                        result.success(
                            Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                                packageManager.canRequestPackageInstalls()
                        )
                    }
                    "openInstallPermissionSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()
                        ) {
                            val settingsIntent = Intent(
                                android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(settingsIntent)
                        }
                        result.success(true)
                    }
                    "installApk" -> {
                        try {
                            val path = call.argument<String>("path")
                                ?: throw IllegalArgumentException("Missing APK path")
                            val apk = File(path)
                            if (!apk.isFile || apk.length() == 0L) {
                                throw IllegalArgumentException("Downloaded APK is missing or empty")
                            }
                            val apkUri = FileProvider.getUriForFile(
                                this,
                                "$packageName.fileprovider",
                                apk
                            )
                            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(
                                    apkUri,
                                    "application/vnd.android.package-archive"
                                )
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(installIntent)
                            result.success(true)
                        } catch (error: Exception) {
                            Log.e(TAG, "Could not launch APK installer", error)
                            result.error("INSTALL_FAILED", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startCaptureService(resultCode: Int, data: Intent) {
        val serviceIntent = Intent(this, ScreenCaptureService::class.java).apply {
            putExtra("resultCode", resultCode)
            putExtra("data", data)
        }
        startForegroundService(serviceIntent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PHONE_PERMISSION_REQUEST_CODE) {
            val granted = grantResults.firstOrNull() ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
            pendingPhonePermissionResult?.success(granted)
            pendingPhonePermissionResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SCREEN_CAPTURE_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                // Store projection data for potential reinitialization later
                projectionResultCode = resultCode
                projectionData = data.clone() as Intent

                Log.d(TAG, "onActivityResult: permission granted, starting capture service")

                startCaptureService(resultCode, data)

                // Wait for the service to fully initialize before returning success.
                // With the callback fix, onStartCommand should reliably initialize.
                // Do NOT try to reinitialize with stored data here — on Android 14+
                // the projection token is single-use and was already consumed by onStartCommand.
                android.os.Handler(mainLooper).postDelayed({
                    val service = ScreenCaptureService.instance
                    if (service != null && service.isInitialized) {
                        Log.d(TAG, "onActivityResult: service initialized successfully")
                        pendingResult?.success(true)
                    } else {
                        Log.w(TAG, "onActivityResult: service not initialized after 1.5s")
                        pendingResult?.success(false)
                    }
                    pendingResult = null
                }, 1500)
            } else {
                Log.w(TAG, "onActivityResult: permission denied or no data")
                pendingResult?.success(false)
                pendingResult = null
            }
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(forceStopReceiver)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to unregister forceStopReceiver", e)
        }
        methodChannel = null
        voiceChannel = null
        super.onDestroy()
    }
}
