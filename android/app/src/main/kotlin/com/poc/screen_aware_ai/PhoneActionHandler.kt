package com.poc.screen_aware_ai

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Environment
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.MediaStore
import android.provider.Settings
import android.content.Context
import android.hardware.camera2.CameraManager
import android.database.Cursor
import android.util.Log
import android.provider.SearchRecentSuggestions
import android.app.SearchManager
import android.content.ContentUris
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Executes low-latency Android intents and device APIs.
 *
 * Consequential communication actions intentionally open the system dialer or
 * SMS composer. Lucy never silently places a call or sends an SMS.
 */
class PhoneActionHandler(private val activity: Activity) {
    companion object {
        private const val TAG = "LucyPhoneActions"
    }

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        return try {
            when (call.method) {
                "set_alarm" -> setAlarm(call, result)
                "set_timer" -> setTimer(call, result)
                "place_call" -> placeCall(call, result)
                "send_sms" -> sendSms(call, result)
                "open_url" -> openUrl(call, result)
                "start_navigation" -> startNavigation(call, result)
                "music_search" -> musicSearch(call, result)
                "set_flashlight" -> setFlashlight(call, result)
                "set_volume" -> setVolume(call, result)
                "set_brightness" -> setBrightness(call, result)
                "get_device_status" -> getDeviceStatus(result)
                "read_contact" -> readContact(call, result)
                "create_calendar_event" -> createCalendarEvent(call, result)
                "open_settings" -> openSettings(call, result)
                "take_photo" -> takePhoto(result)
                "share_text" -> shareText(call, result)
                else -> return false
            }
            true
        } catch (error: SecurityException) {
            Log.w(TAG, "Permission or platform access denied for ${call.method}", error)
            result.error("PHONE_ACTION_DENIED", "Android denied this action.", null)
            true
        } catch (error: ActivityNotFoundException) {
            Log.w(TAG, "No activity can handle ${call.method}", error)
            result.success(false)
            true
        } catch (error: Exception) {
            Log.e(TAG, "Phone action failed: ${call.method}", error)
            result.error("PHONE_ACTION_FAILED", error.message ?: "Android action failed.", null)
            true
        }
    }

    private fun launch(intent: Intent): Boolean {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (intent.resolveActivity(activity.packageManager) == null) return false
        activity.startActivity(intent)
        return true
    }

    private fun setAlarm(call: MethodCall, result: MethodChannel.Result) {
        val hour = call.argument<Int>("hour")
        val minute = call.argument<Int>("minute")
        if (hour == null || minute == null || hour !in 0..23 || minute !in 0..59) {
            result.error("INVALID_ARGUMENT", "Alarm hour or minute is invalid.", null)
            return
        }
        val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
            putExtra(AlarmClock.EXTRA_HOUR, hour)
            putExtra(AlarmClock.EXTRA_MINUTES, minute)
            putExtra(AlarmClock.EXTRA_MESSAGE, call.argument<String>("message") ?: "Lucy alarm")
            putExtra(AlarmClock.EXTRA_SKIP_UI, false)
        }
        result.success(launch(intent))
    }

    private fun setTimer(call: MethodCall, result: MethodChannel.Result) {
        val seconds = call.argument<Int>("durationSeconds") ?: 0
        if (seconds !in 1..86400) {
            result.error("INVALID_ARGUMENT", "Timer duration must be between 1 second and 24 hours.", null)
            return
        }
        val intent = Intent(AlarmClock.ACTION_SET_TIMER).apply {
            putExtra(AlarmClock.EXTRA_LENGTH, seconds)
            putExtra(AlarmClock.EXTRA_MESSAGE, call.argument<String>("message") ?: "Lucy timer")
            putExtra(AlarmClock.EXTRA_SKIP_UI, false)
        }
        result.success(launch(intent))
    }

    private fun placeCall(call: MethodCall, result: MethodChannel.Result) {
        val number = call.argument<String>("phoneNumber")?.trim().orEmpty()
        if (number.isBlank()) {
            result.error("INVALID_ARGUMENT", "A phone number is required.", null)
            return
        }
        val keyguard = activity.getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
        if (keyguard.isKeyguardLocked) {
            // Never try to dismiss or bypass the user's secure lock screen.
            // The caller can retry after the user authenticates.
            result.success(mapOf("success" to false, "requiresUnlock" to true))
            return
        }
        // ACTION_DIAL leaves the final call decision with the user.
        result.success(launch(Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", number, null))))
    }

    private fun sendSms(call: MethodCall, result: MethodChannel.Result) {
        val number = call.argument<String>("phoneNumber")?.trim().orEmpty()
        val body = call.argument<String>("message") ?: ""
        if (number.isBlank() || body.isBlank()) {
            result.error("INVALID_ARGUMENT", "A phone number and message are required.", null)
            return
        }
        val intent = Intent(Intent.ACTION_SENDTO, Uri.fromParts("smsto", number, null)).apply {
            putExtra("sms_body", body)
        }
        result.success(launch(intent))
    }

    private fun openUrl(call: MethodCall, result: MethodChannel.Result) {
        val raw = call.argument<String>("url")?.trim().orEmpty()
        val uri = Uri.parse(raw)
        if (raw.isBlank() || (uri.scheme != "https" && uri.scheme != "http") || uri.host.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "Only valid HTTP or HTTPS URLs can be opened.", null)
            return
        }
        result.success(launch(Intent(Intent.ACTION_VIEW, uri)))
    }

    private fun startNavigation(call: MethodCall, result: MethodChannel.Result) {
        val destination = call.argument<String>("destination")?.trim().orEmpty()
        if (destination.isBlank()) {
            result.error("INVALID_ARGUMENT", "A navigation destination is required.", null)
            return
        }
        val uri = Uri.parse("google.navigation:q=${Uri.encode(destination)}")
        result.success(launch(Intent(Intent.ACTION_VIEW, uri).setPackage("com.google.android.apps.maps"))
            || launch(Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=${Uri.encode(destination)}"))))
    }

    private fun musicSearch(call: MethodCall, result: MethodChannel.Result) {
        val query = call.argument<String>("query")?.trim().orEmpty()
        if (query.isBlank()) {
            result.error("INVALID_ARGUMENT", "A music search query is required.", null)
            return
        }
        val intent = Intent("android.media.action.MEDIA_PLAY_FROM_SEARCH").apply {
            putExtra(SearchManager.QUERY, query)
        }
        result.success(launch(intent))
    }

    private fun setFlashlight(call: MethodCall, result: MethodChannel.Result) {
        if (activity.checkSelfPermission(android.Manifest.permission.CAMERA) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED) {
            result.error("PERMISSION_REQUIRED", android.Manifest.permission.CAMERA, null)
            return
        }
        val enabled = call.argument<Boolean>("enabled") ?: true
        val cameraManager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = cameraManager.cameraIdList.firstOrNull { id ->
            cameraManager.getCameraCharacteristics(id)
                .get(android.hardware.camera2.CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        }
        if (cameraId == null) {
            result.success(false)
            return
        }
        cameraManager.setTorchMode(cameraId, enabled)
        result.success(true)
    }

    private fun setVolume(call: MethodCall, result: MethodChannel.Result) {
        val audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val stream = when ((call.argument<String>("stream") ?: "music").lowercase(Locale.ROOT)) {
            "ring", "ringtone" -> AudioManager.STREAM_RING
            "alarm" -> AudioManager.STREAM_ALARM
            "notification" -> AudioManager.STREAM_NOTIFICATION
            "voice", "call" -> AudioManager.STREAM_VOICE_CALL
            else -> AudioManager.STREAM_MUSIC
        }
        val direction = call.argument<String>("direction")?.lowercase(Locale.ROOT)
        val requested = call.argument<Int>("level")
        val max = audio.getStreamMaxVolume(stream)
        val current = audio.getStreamVolume(stream)
        val next = when (direction) {
            "up" -> (current + 1).coerceAtMost(max)
            "down" -> (current - 1).coerceAtLeast(0)
            "mute" -> 0
            else -> {
                if (requested == null || requested !in 0..100) {
                    result.error("INVALID_ARGUMENT", "Volume level must be from 0 to 100.", null)
                    return
                }
                (requested * max / 100.0).toInt().coerceIn(0, max)
            }
        }
        audio.setStreamVolume(stream, next, AudioManager.FLAG_SHOW_UI)
        result.success(mapOf("level" to next, "max" to max, "stream" to stream))
    }

    private fun setBrightness(call: MethodCall, result: MethodChannel.Result) {
        val percent = call.argument<Int>("level")
        if (percent == null || percent !in 1..100) {
            result.error("INVALID_ARGUMENT", "Brightness must be from 1 to 100 percent.", null)
            return
        }
        if (!Settings.System.canWrite(activity)) {
            val settingsIntent = Intent(
                Settings.ACTION_MANAGE_WRITE_SETTINGS,
                Uri.parse("package:${activity.packageName}")
            )
            result.success(mapOf("success" to false, "requiresSettingsAccess" to launch(settingsIntent)))
            return
        }
        Settings.System.putInt(activity.contentResolver, Settings.System.SCREEN_BRIGHTNESS_MODE,
            Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL)
        val value = (percent * 255 / 100).coerceIn(1, 255)
        val success = Settings.System.putInt(
            activity.contentResolver,
            Settings.System.SCREEN_BRIGHTNESS,
            value
        )
        result.success(mapOf("success" to success, "level" to percent))
    }

    private fun getDeviceStatus(result: MethodChannel.Result) {
        val batteryManager = activity.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val battery = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val batteryIntent = activity.registerReceiver(null, android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val status = batteryIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        val data = Environment.getDataDirectory()
        result.success(mapOf(
            "batteryPercent" to if (battery in 0..100) battery else null,
            "charging" to charging,
            "storageTotalBytes" to data.totalSpace,
            "storageFreeBytes" to data.usableSpace
        ))
    }

    private fun readContact(call: MethodCall, result: MethodChannel.Result) {
        if (activity.checkSelfPermission(android.Manifest.permission.READ_CONTACTS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED) {
            result.error("PERMISSION_REQUIRED", android.Manifest.permission.READ_CONTACTS, null)
            return
        }
        val query = call.argument<String>("name")?.trim().orEmpty()
        if (query.isBlank()) {
            result.error("INVALID_ARGUMENT", "A contact name is required.", null)
            return
        }

        // Search the local address book rather than relying on SQL LIKE. Speech
        // recognition often produces phonetic spellings such as "pappa" for
        // a saved contact named "Papa". No contact data leaves this device here.
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER,
            ContactsContract.CommonDataKinds.Phone.TYPE
        )
        val candidates = mutableListOf<LucyContactCandidate>()
        activity.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            projection,
            null,
            null,
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC"
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.CONTACT_ID)
            val nameIndex = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
            val numberIndex = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
            val typeIndex = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.TYPE)
            while (cursor.moveToNext() && candidates.size < 3000) {
                val type = if (typeIndex >= 0) cursor.getInt(typeIndex) else -1
                val typeLabel = when (type) {
                    ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE -> "mobile"
                    ContactsContract.CommonDataKinds.Phone.TYPE_HOME -> "home"
                    ContactsContract.CommonDataKinds.Phone.TYPE_WORK -> "work"
                    ContactsContract.CommonDataKinds.Phone.TYPE_MAIN -> "main"
                    else -> "other"
                }
                candidates.add(
                    LucyContactCandidate(
                        contactId = if (idIndex >= 0) cursor.getString(idIndex).orEmpty() else "",
                        name = if (nameIndex >= 0) cursor.getString(nameIndex).orEmpty() else "",
                        phoneNumber = if (numberIndex >= 0) cursor.getString(numberIndex).orEmpty() else "",
                        typeLabel = typeLabel
                    )
                )
            }
        }

        val matches = LucyContactMatcher.bestMatches(query, candidates)
        when {
            matches.isEmpty() -> result.success(
                mapOf("found" to false, "ambiguous" to false, "query" to query)
            )
            matches.size > 1 -> {
                // Never silently call the first of several plausible matches.
                // Show contact names and number type, with only a tiny suffix
                // when duplicate names need to be distinguished.
                val choices = matches.map { match ->
                    val suffix = match.phoneNumber.filter(Char::isDigit).takeLast(2)
                    mapOf(
                        "name" to match.name,
                        "type" to match.typeLabel,
                        "numberHint" to if (suffix.isNotEmpty()) "ending $suffix" else ""
                    )
                }
                result.success(
                    mapOf("found" to false, "ambiguous" to true, "matches" to choices)
                )
            }
            else -> {
                val match = matches.single()
                result.success(
                    mapOf(
                        "found" to true,
                        "name" to match.name,
                        "phoneNumber" to match.phoneNumber,
                        "type" to match.typeLabel
                    )
                )
            }
        }
    }

    private fun createCalendarEvent(call: MethodCall, result: MethodChannel.Result) {
        val title = call.argument<String>("title")?.trim().orEmpty()
        val begin = call.argument<Number>("startTimeMillis")?.toLong()
        val end = call.argument<Number>("endTimeMillis")?.toLong()
        if (title.isBlank() || begin == null || end == null || end <= begin) {
            result.error("INVALID_ARGUMENT", "A title and valid start/end times are required.", null)
            return
        }
        val intent = Intent(Intent.ACTION_INSERT).setData(CalendarContract.Events.CONTENT_URI).apply {
            putExtra(CalendarContract.Events.TITLE, title)
            putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, begin)
            putExtra(CalendarContract.EXTRA_EVENT_END_TIME, end)
            putExtra(CalendarContract.Events.DESCRIPTION, call.argument<String>("description") ?: "")
            putExtra(CalendarContract.Events.EVENT_LOCATION, call.argument<String>("location") ?: "")
        }
        result.success(launch(intent))
    }

    private fun openSettings(call: MethodCall, result: MethodChannel.Result) {
        val action = when ((call.argument<String>("page") ?: "general").lowercase(Locale.ROOT)) {
            "wifi" -> Settings.ACTION_WIFI_SETTINGS
            "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
            "display" -> Settings.ACTION_DISPLAY_SETTINGS
            "sound" -> Settings.ACTION_SOUND_SETTINGS
            "apps" -> Settings.ACTION_APPLICATION_SETTINGS
            "accessibility" -> Settings.ACTION_ACCESSIBILITY_SETTINGS
            "location" -> Settings.ACTION_LOCATION_SOURCE_SETTINGS
            "battery" -> Settings.ACTION_BATTERY_SAVER_SETTINGS
            "wireless" -> Settings.ACTION_WIRELESS_SETTINGS
            else -> Settings.ACTION_SETTINGS
        }
        result.success(launch(Intent(action)))
    }

    private fun takePhoto(result: MethodChannel.Result) {
        result.success(launch(Intent(MediaStore.ACTION_IMAGE_CAPTURE)))
    }

    private fun shareText(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text")?.trim().orEmpty()
        if (text.isBlank()) {
            result.error("INVALID_ARGUMENT", "Text to share cannot be empty.", null)
            return
        }
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
        }
        activity.startActivity(Intent.createChooser(send, "Share with Lucy"))
        result.success(true)
    }
}
