package com.poc.screen_aware_ai

import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.net.Uri
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.Settings
import android.media.AudioManager
import android.hardware.camera2.CameraManager
import android.os.BatteryManager
import android.os.Environment
import android.os.StatFs
import android.content.Context
import java.util.Locale

/**
 * Native, intent-first phone actions. Actions that can send or place communications
 * deliberately open the system composer/dialer; Lucy never sends them silently.
 */
object NativePhoneActions {
    fun execute(activity: Activity, action: String, args: Map<String, Any?>): Map<String, Any?> {
        return when (action) {
            "set_alarm" -> {
                val hour = (args["hour"] as? Number)?.toInt() ?: error("Missing hour")
                val minute = (args["minute"] as? Number)?.toInt() ?: 0
                require(hour in 0..23 && minute in 0..59) { "Invalid alarm time" }
                val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
                    putExtra(AlarmClock.EXTRA_HOUR, hour)
                    putExtra(AlarmClock.EXTRA_MINUTES, minute)
                    putExtra(AlarmClock.EXTRA_MESSAGE, args["label"] as? String ?: "Lucy alarm")
                    putExtra(AlarmClock.EXTRA_SKIP_UI, false)
                }
                launch(activity, intent)
            }
            "set_timer" -> {
                val seconds = (args["seconds"] as? Number)?.toInt() ?: error("Missing seconds")
                require(seconds in 1..86400) { "Timer must be between 1 second and 24 hours" }
                launch(activity, Intent(AlarmClock.ACTION_SET_TIMER).apply {
                    putExtra(AlarmClock.EXTRA_LENGTH, seconds)
                    putExtra(AlarmClock.EXTRA_MESSAGE, args["label"] as? String ?: "Lucy timer")
                    putExtra(AlarmClock.EXTRA_SKIP_UI, false)
                })
            }
            "place_call" -> {
                val number = args["phone_number"] as? String ?: error("Missing phone number")
                require(number.isNotBlank()) { "Phone number is empty" }
                launch(activity, Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", number, null)))
            }
            "send_sms" -> {
                val number = args["phone_number"] as? String ?: ""
                val body = args["message"] as? String ?: ""
                require(number.isNotBlank()) { "Missing recipient number" }
                launch(activity, Intent(Intent.ACTION_SENDTO, Uri.fromParts("smsto", number, null)).apply {
                    putExtra("sms_body", body)
                })
            }
            "open_url" -> {
                val raw = args["url"] as? String ?: error("Missing URL")
                val uri = Uri.parse(raw)
                require(uri.scheme == "https" || uri.scheme == "http") { "Only HTTP and HTTPS links are allowed" }
                launch(activity, Intent(Intent.ACTION_VIEW, uri))
            }
            "maps_navigate" -> {
                val destination = args["destination"] as? String ?: error("Missing destination")
                require(destination.isNotBlank()) { "Destination is empty" }
                val uri = Uri.parse("google.navigation:q=" + Uri.encode(destination))
                launch(activity, Intent(Intent.ACTION_VIEW, uri).setPackage("com.google.android.apps.maps"))
            }
            "music_search" -> {
                val query = args["query"] as? String ?: error("Missing search query")
                require(query.isNotBlank()) { "Search query is empty" }
                launch(activity, Intent(Intent.ACTION_VIEW, Uri.parse("https://www.youtube.com/results?search_query=" + Uri.encode(query))))
            }
            "flashlight" -> {
                val enabled = args["enabled"] as? Boolean ?: true
                val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                val cameraId = manager.cameraIdList.firstOrNull { id ->
                    manager.getCameraCharacteristics(id).get(android.hardware.camera2.CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
                } ?: error("No flashlight is available")
                manager.setTorchMode(cameraId, enabled)
                mapOf("success" to true, "message" to if (enabled) "Flashlight enabled" else "Flashlight disabled")
            }
            "set_volume" -> {
                val percent = (args["percent"] as? Number)?.toInt() ?: error("Missing percent")
                require(percent in 0..100) { "Volume must be 0 to 100" }
                val stream = (activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager)
                val max = stream.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                stream.setStreamVolume(AudioManager.STREAM_MUSIC, (max * percent / 100.0).toInt(), 0)
                mapOf("success" to true, "message" to "Media volume set to $percent percent")
            }
            "set_brightness" -> {
                val percent = (args["percent"] as? Number)?.toInt() ?: error("Missing percent")
                require(percent in 1..100) { "Brightness must be 1 to 100" }
                if (!Settings.System.canWrite(activity)) {
                    val permissionIntent = Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:${activity.packageName}"))
                    activity.startActivity(permissionIntent)
                    mapOf("success" to false, "permission_required" to true, "message" to "Allow Lucy to modify system settings, then repeat the command")
                } else {
                    Settings.System.putInt(activity.contentResolver, Settings.System.SCREEN_BRIGHTNESS, (percent * 255 / 100).coerceIn(1, 255))
                    mapOf("success" to true, "message" to "Brightness set to $percent percent")
                }
            }
            "battery_status" -> {
                val battery = activity.registerReceiver(null, android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
                val percent = if (level >= 0 && scale > 0) level * 100 / scale else -1
                val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                mapOf("success" to true, "level_percent" to percent, "charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL))
            }
            "storage_status" -> {
                val stat = StatFs(Environment.getDataDirectory().path)
                val total = stat.totalBytes
                val available = stat.availableBytes
                mapOf("success" to true, "total_bytes" to total, "available_bytes" to available, "used_bytes" to total - available)
            }
            "create_calendar_event" -> {
                val title = args["title"] as? String ?: error("Missing event title")
                val begin = (args["begin_time_millis"] as? Number)?.toLong() ?: error("Missing event start time")
                val end = (args["end_time_millis"] as? Number)?.toLong() ?: error("Missing event end time")
                require(title.isNotBlank() && end > begin) { "Invalid event details" }
                val intent = Intent(Intent.ACTION_INSERT).setData(CalendarContract.Events.CONTENT_URI).apply {
                    putExtra(CalendarContract.Events.TITLE, title)
                    putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, begin)
                    putExtra(CalendarContract.EXTRA_EVENT_END_TIME, end)
                    (args["description"] as? String)?.let { putExtra(CalendarContract.Events.DESCRIPTION, it) }
                }
                launch(activity, intent)
            }
            "open_settings" -> {
                val page = args["page"] as? String ?: "general"
                val actionName = when (page.lowercase(Locale.ROOT)) {
                    "wifi" -> Settings.ACTION_WIFI_SETTINGS
                    "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
                    "display" -> Settings.ACTION_DISPLAY_SETTINGS
                    "sound" -> Settings.ACTION_SOUND_SETTINGS
                    "battery" -> Settings.ACTION_BATTERY_SAVER_SETTINGS
                    "apps" -> Settings.ACTION_APPLICATION_SETTINGS
                    "accessibility" -> Settings.ACTION_ACCESSIBILITY_SETTINGS
                    "location" -> Settings.ACTION_LOCATION_SOURCE_SETTINGS
                    "general" -> Settings.ACTION_SETTINGS
                    else -> error("Unsupported settings page")
                }
                launch(activity, Intent(actionName))
            }
            "take_photo" -> launch(activity, Intent("android.media.action.IMAGE_CAPTURE"))
            "share_text" -> {
                val text = args["text"] as? String ?: error("Missing text")
                require(text.isNotBlank()) { "Nothing to share" }
                launch(activity, Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text).let { Intent.createChooser(it, "Share with") })
            }
            "find_contact" -> {
                val name = args["name"] as? String ?: error("Missing contact name")
                require(name.isNotBlank()) { "Contact name is empty" }
                val uri = ContactsContract.CommonDataKinds.Phone.CONTENT_URI
                val cursor = activity.contentResolver.query(
                    uri,
                    arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME, ContactsContract.CommonDataKinds.Phone.NUMBER),
                    "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?",
                    arrayOf("%$name%"),
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " ASC"
                )
                cursor?.use {
                    if (it.moveToFirst()) {
                        val displayName = it.getString(0) ?: name
                        val number = it.getString(1) ?: ""
                        mapOf("success" to true, "name" to displayName, "phone_number" to number)
                    } else mapOf("success" to false, "message" to "No matching contact found")
                } ?: mapOf("success" to false, "message" to "Could not read contacts")
            }
            else -> error("Unsupported native action: $action")
        }
    }

    private fun launch(activity: Activity, intent: Intent): Map<String, Any?> {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (intent.resolveActivity(activity.packageManager) == null) {
            return mapOf("success" to false, "message" to "No app can handle this action")
        }
        activity.startActivity(intent)
        return mapOf("success" to true, "message" to "Opened the relevant Android app")
    }
}
