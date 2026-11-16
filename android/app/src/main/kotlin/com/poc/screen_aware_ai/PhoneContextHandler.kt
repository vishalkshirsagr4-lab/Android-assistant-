package com.poc.screen_aware_ai

import android.Manifest
import android.app.Activity
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Process
import android.provider.CalendarContract
import android.provider.Settings
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import androidx.core.content.ContextCompat
import org.json.JSONArray
import java.util.concurrent.TimeUnit

/**
 * Small on-demand context snapshot for Lucy. It does not run a polling loop.
 * Optional sources are omitted unless the user has granted the matching access.
 */
class PhoneContextHandler(private val activity: Activity) {

    fun handle(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result): Boolean {
        when (call.method) {
            "getContextSnapshot" -> {
                result.success(getContextSnapshot())
                return true
            }
            "openNotificationAccessSettings" -> {
                openSettings(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS, result)
                return true
            }
            "openUsageAccessSettings" -> {
                openSettings(Settings.ACTION_USAGE_ACCESS_SETTINGS, result)
                return true
            }
            "setNotificationContextEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") == true
                activity.getSharedPreferences(
                    NotificationContextListener.PREFERENCES_NAME,
                    Context.MODE_PRIVATE
                ).edit().putBoolean(
                    NotificationContextListener.NOTIFICATION_ENABLED_KEY,
                    enabled
                ).apply()
                if (!enabled) {
                    activity.getSharedPreferences(
                        NotificationContextListener.PREFERENCES_NAME,
                        Context.MODE_PRIVATE
                    ).edit().remove(NotificationContextListener.NOTIFICATION_KEY).apply()
                }
                result.success(true)
                return true
            }
            "clearNotificationHistory" -> {
                activity.getSharedPreferences(
                    NotificationContextListener.PREFERENCES_NAME,
                    Context.MODE_PRIVATE
                ).edit().remove(NotificationContextListener.NOTIFICATION_KEY).apply()
                result.success(true)
                return true
            }
            "setLocationContextEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") == true
                val granted = ContextCompat.checkSelfPermission(
                    activity,
                    Manifest.permission.ACCESS_COARSE_LOCATION
                ) == PackageManager.PERMISSION_GRANTED
                if (enabled && !granted) {
                    result.success(false)
                } else {
                    activity.getSharedPreferences(
                        NotificationContextListener.PREFERENCES_NAME,
                        Context.MODE_PRIVATE
                    ).edit().putBoolean(
                        NotificationContextListener.LOCATION_ENABLED_KEY,
                        enabled
                    ).apply()
                    result.success(true)
                }
                return true
            }
            else -> return false
        }
    }

    private fun openSettings(action: String, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            activity.startActivity(Intent(action))
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    private fun getContextSnapshot(): Map<String, Any?> {
        val batteryIntent = activity.registerReceiver(
            null,
            android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        )
        val batteryLevel = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val batteryScale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val batteryPercent = if (batteryLevel >= 0 && batteryScale > 0) {
            (batteryLevel * 100 / batteryScale).coerceIn(0, 100)
        } else null
        val batteryStatus = batteryIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = batteryStatus == BatteryManager.BATTERY_STATUS_CHARGING ||
            batteryStatus == BatteryManager.BATTERY_STATUS_FULL

        return mapOf(
            "batteryPercent" to batteryPercent,
            "charging" to charging,
            "network" to getNetworkState(),
            "foregroundApp" to getForegroundApp(),
            "notifications" to getRecentNotifications(),
            "notificationAccessEnabled" to isNotificationAccessEnabled(),
            "notificationContextEnabled" to activity.getSharedPreferences(
                NotificationContextListener.PREFERENCES_NAME,
                Context.MODE_PRIVATE
            ).getBoolean(NotificationContextListener.NOTIFICATION_ENABLED_KEY, false),
            "usageAccessEnabled" to hasUsageAccess(),
            "calendarAccessEnabled" to hasCalendarAccess(),
            "calendarEvents" to getUpcomingCalendarEvents(),
            "locationEnabled" to isLocationContextEnabled(),
            "approximateLocation" to getApproximateLocation()
        )
    }

    private fun getNetworkState(): String {
        val manager = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = manager.activeNetwork ?: return "offline"
        val capabilities = manager.getNetworkCapabilities(network) ?: return "disconnected"
        if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
            return "no internet"
        }
        val transport = when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile data"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
            else -> "network"
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        ) "$transport connected" else "$transport available; internet not verified"
    }

    private fun hasUsageAccess(): Boolean {
        val appOps = activity.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = appOps.checkOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS,
            Process.myUid(),
            activity.packageName
        )
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun getForegroundApp(): String? {
        if (!hasUsageAccess()) return null
        return try {
            val manager = activity.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val end = System.currentTimeMillis()
            // A foreground activity can remain open for hours without a new
            // event, so inspect a bounded day of transitions rather than only
            // the last few minutes.
            val events = manager.queryEvents(end - TimeUnit.HOURS.toMillis(24), end)
                ?: return null
            val event = UsageEvents.Event()
            var foregroundPackage: String? = null
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    when (event.eventType) {
                        UsageEvents.Event.ACTIVITY_RESUMED -> {
                            foregroundPackage = event.packageName
                        }
                        UsageEvents.Event.ACTIVITY_PAUSED -> {
                            if (foregroundPackage == event.packageName) {
                                foregroundPackage = null
                            }
                        }
                    }
                } else {
                    @Suppress("DEPRECATION")
                    when (event.eventType) {
                        UsageEvents.Event.MOVE_TO_FOREGROUND -> {
                            foregroundPackage = event.packageName
                        }
                        UsageEvents.Event.MOVE_TO_BACKGROUND -> {
                            if (foregroundPackage == event.packageName) {
                                foregroundPackage = null
                            }
                        }
                    }
                }
            }
            if (foregroundPackage == activity.packageName) foregroundPackage = null
            foregroundPackage?.let { packageName ->
                activity.packageManager.getApplicationLabel(
                    activity.packageManager.getApplicationInfo(packageName, 0)
                ).toString().take(60)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun isNotificationAccessEnabled(): Boolean {
        val enabled = Settings.Secure.getString(
            activity.contentResolver,
            "enabled_notification_listeners"
        ) ?: return false
        return enabled.split(':').any { component ->
            component.startsWith(activity.packageName + "/")
        }
    }

    private fun getRecentNotifications(): List<Map<String, Any>> {
        if (!isNotificationAccessEnabled()) return emptyList()
        val preferences = activity.getSharedPreferences(
            NotificationContextListener.PREFERENCES_NAME,
            Context.MODE_PRIVATE
        )
        if (!preferences.getBoolean(NotificationContextListener.NOTIFICATION_ENABLED_KEY, false)) {
            return emptyList()
        }
        val raw = activity.getSharedPreferences(
            NotificationContextListener.PREFERENCES_NAME,
            Context.MODE_PRIVATE
        ).getString(NotificationContextListener.NOTIFICATION_KEY, "[]") ?: "[]"
        return try {
            val array = JSONArray(raw)
            val cutoff = System.currentTimeMillis() - TimeUnit.HOURS.toMillis(24)
            val start = (array.length() - 20).coerceAtLeast(0)
            (start until array.length()).mapNotNull { index ->
                val item = array.optJSONObject(index) ?: return@mapNotNull null
                if (item.optLong("timestamp") < cutoff) return@mapNotNull null
                mapOf(
                    "app" to item.optString("app"),
                    "sender" to item.optString("sender"),
                    "title" to item.optString("title"),
                    "text" to item.optString("text"),
                    "timestamp" to item.optLong("timestamp")
                )
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun hasCalendarAccess(): Boolean =
        ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.READ_CALENDAR
        ) == PackageManager.PERMISSION_GRANTED

    private fun getUpcomingCalendarEvents(): List<Map<String, Any>> {
        if (!hasCalendarAccess()) return emptyList()
        val now = System.currentTimeMillis()
        val end = now + TimeUnit.HOURS.toMillis(6)
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
            .appendPath(now.toString())
            .appendPath(end.toString())
            .build()
        val projection = arrayOf(
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.EVENT_LOCATION
        )
        return try {
            val events = mutableListOf<Map<String, Any>>()
            activity.contentResolver.query(
                uri,
                projection,
                null,
                null,
                CalendarContract.Instances.BEGIN + " ASC"
            )?.use { cursor ->
                val titleIndex = cursor.getColumnIndex(CalendarContract.Instances.TITLE)
                val beginIndex = cursor.getColumnIndex(CalendarContract.Instances.BEGIN)
                val endIndex = cursor.getColumnIndex(CalendarContract.Instances.END)
                val locationIndex = cursor.getColumnIndex(CalendarContract.Instances.EVENT_LOCATION)
                while (cursor.moveToNext() && events.size < 5) {
                    val begin = cursor.getLong(beginIndex)
                    if (begin < now) continue
                    events.add(
                        mapOf(
                            "title" to cursor.getString(titleIndex).orEmpty().take(100),
                            "startTimeMillis" to begin,
                            "endTimeMillis" to cursor.getLong(endIndex),
                            "location" to cursor.getString(locationIndex).orEmpty().take(80)
                        )
                    )
                }
            }
            events
        } catch (_: SecurityException) {
            emptyList()
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun isLocationContextEnabled(): Boolean {
        val optedIn = activity.getSharedPreferences(
            NotificationContextListener.PREFERENCES_NAME,
            Context.MODE_PRIVATE
        ).getBoolean(NotificationContextListener.LOCATION_ENABLED_KEY, false)
        return optedIn && ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun getApproximateLocation(): Map<String, Double>? {
        if (!isLocationContextEnabled() ||
            ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.ACCESS_COARSE_LOCATION
            ) != PackageManager.PERMISSION_GRANTED
        ) return null

        return try {
            val manager = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val providers = manager.getProviders(true)
            val location: Location = providers.mapNotNull { provider ->
                try {
                    manager.getLastKnownLocation(provider)
                } catch (_: SecurityException) {
                    null
                }
            }.maxByOrNull { it.time } ?: return null
            // Round to roughly kilometre-scale precision before sharing with an AI provider.
            mapOf(
                "latitude" to String.format(java.util.Locale.US, "%.2f", location.latitude).toDouble(),
                "longitude" to String.format(java.util.Locale.US, "%.2f", location.longitude).toDouble()
            )
        } catch (_: Exception) {
            null
        }
    }
}
