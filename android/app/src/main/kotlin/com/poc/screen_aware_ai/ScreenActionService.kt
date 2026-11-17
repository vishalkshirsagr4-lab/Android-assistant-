package com.poc.screen_aware_ai

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.Rect
import android.graphics.PixelFormat
import android.os.Bundle
import android.os.PowerManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.app.KeyguardManager
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

class ScreenActionService : AccessibilityService() {

    companion object {
        var instance: ScreenActionService? = null
        private const val TAG = "ScreenActionService"
    }

    private var keepAwakeView: View? = null
    private var screenWakeLock: PowerManager.WakeLock? = null
    private val watcherHandler = Handler(Looper.getMainLooper())
    @Volatile private var watcherEnabled = true
    @Volatile private var autoSkipAds = true
    @Volatile private var autoDismissPopups = true
    @Volatile private var excludedWatcherPackages: Set<String> = emptySet()
    private var lastWatcherClickAt = 0L
    private var lastWatcherClickKey = ""
    @Volatile private var cancelDeepScroll = false
    private val watcherRunnable = Runnable { inspectAndHandleSafeOverlay() }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        val preferences = getSharedPreferences("lucy_screen_watcher", MODE_PRIVATE)
        watcherEnabled = preferences.getBoolean("enabled", true)
        autoSkipAds = preferences.getBoolean("skip_ads", true)
        autoDismissPopups = preferences.getBoolean("dismiss_popups", true)
        excludedWatcherPackages = preferences.getStringSet("excluded_packages", emptySet())?.toSet() ?: emptySet()
        Log.d(TAG, "Accessibility service connected")
    }

    private val uiEventLock = ReentrantLock()
    private val uiEventChanged = uiEventLock.newCondition()
    @Volatile private var uiEventSequence: Long = 0L

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_VIEW_SCROLLED,
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED -> {
                uiEventLock.lock()
                try {
                    uiEventSequence += 1L
                    uiEventChanged.signalAll()
                } finally {
                    uiEventLock.unlock()
                }
                if (event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED ||
                    event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
                ) {
                    if (watcherEnabled) {
                        watcherHandler.removeCallbacks(watcherRunnable)
                        watcherHandler.postDelayed(watcherRunnable, 650L)
                    }
                }
            }
        }
    }

    /** Conservative watcher: system permission and sensitive screens remain manual. */
    fun configureScreenWatcher(
        enabled: Boolean,
        skipAds: Boolean,
        dismissPopups: Boolean,
        excludedPackages: Set<String>
    ): Boolean {
        watcherEnabled = enabled
        autoSkipAds = skipAds
        autoDismissPopups = dismissPopups
        excludedWatcherPackages = excludedPackages
        getSharedPreferences("lucy_screen_watcher", MODE_PRIVATE).edit()
            .putBoolean("enabled", enabled)
            .putBoolean("skip_ads", skipAds)
            .putBoolean("dismiss_popups", dismissPopups)
            .putStringSet("excluded_packages", excludedPackages)
            .apply()
        if (!enabled) watcherHandler.removeCallbacks(watcherRunnable)
        return true
    }

    /** Requests cancellation of the current bounded deep-scroll operation. */
    fun cancelScreenOperation(): Boolean {
        cancelDeepScroll = true
        return true
    }

    private fun inspectAndHandleSafeOverlay() {
        if (!watcherEnabled || isDeviceLocked()) return
        val root = rootInActiveWindow ?: return
        try {
            val foregroundPackage = root.packageName?.toString().orEmpty()
            if (isWatcherExcludedPackage(foregroundPackage) || isSensitiveScreen(root)) return
            var visited = 0
            var clicked = false
            fun visit(node: AccessibilityNodeInfo, depth: Int) {
                if (clicked || visited >= 400 || depth > 24) return
                visited++
                if (!node.isVisibleToUser || node.isPassword) return
                val text = node.text?.toString()?.trim().orEmpty()
                val desc = node.contentDescription?.toString()?.trim().orEmpty()
                val viewId = node.viewIdResourceName?.substringAfterLast('/')?.lowercase().orEmpty()
                val normalized = (if (text.isNotEmpty()) text else desc)
                    .trim().lowercase().replace(Regex("\\s+"), " ")
                val isAdSkipId = viewId.endsWith("skip_ad_button") ||
                    viewId.endsWith("skip_ads_button") || viewId.endsWith("ad_skip_button")
                val isAdSkipLabel = normalized in setOf("skip", "skip ad", "skip ads", "close ad")
                val isSafePopupLabel = normalized in setOf(
                    "not now", "maybe later", "no thanks", "dismiss", "got it", "reject all"
                )
                val shouldClick = (autoSkipAds && (isAdSkipId || isAdSkipLabel)) ||
                    (autoDismissPopups && isSafePopupLabel)
                if (shouldClick) {
                    val key = "$foregroundPackage|$viewId|$normalized"
                    val now = SystemClock.elapsedRealtime()
                    if (!(key == lastWatcherClickKey && now - lastWatcherClickAt < 1800L)) {
                        val target = findClickableAncestor(node)
                        if (target != null) {
                            try {
                                clicked = target.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                                if (clicked) {
                                    lastWatcherClickKey = key
                                    lastWatcherClickAt = now
                                    Log.d(TAG, "ScreenWatcher handled a safe overlay")
                                }
                            } finally {
                                target.recycle()
                            }
                        }
                    }
                    if (clicked) return
                }
                for (index in 0 until node.childCount) {
                    if (clicked || visited >= 400) break
                    val child = node.getChild(index) ?: continue
                    try { visit(child, depth + 1) } finally { child.recycle() }
                }
            }
            visit(root, 0)
        } catch (error: Exception) {
            Log.w(TAG, "ScreenWatcher inspection failed", error)
        } finally {
            root.recycle()
        }
    }

    private fun findClickableAncestor(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var current = AccessibilityNodeInfo.obtain(node)
        repeat(12) {
            if (current.isClickable && current.isEnabled) return current
            val parent = current.parent ?: run {
                current.recycle()
                return null
            }
            current.recycle()
            current = parent
        }
        current.recycle()
        return null
    }

    private fun isWatcherExcludedPackage(packageName: String): Boolean {
        val lower = packageName.lowercase()
        if (lower in excludedWatcherPackages) return true
        if (lower in setOf(
            "com.android.permissioncontroller", "com.google.android.permissioncontroller",
            "com.android.packageinstaller", "com.android.systemui", "com.google.android.packageinstaller"
        )) return true
        return listOf(
            "bank", "wallet", "payment", "paytm", "phonepe", "gpay",
            "google.android.apps.authenticator", "authenticator", "password", "1password"
        ).any(lower::contains)
    }

    private fun isSensitiveScreen(root: AccessibilityNodeInfo): Boolean {
        val sensitiveTerms = listOf(
            "payment", "pay now", "upi", "bank account", "transfer money",
            "enter otp", "verification code", "cvv", "card number",
            "password", "passcode", "recovery code", "two-factor"
        )
        var visited = 0
        var sensitive = false
        fun visit(node: AccessibilityNodeInfo, depth: Int) {
            if (sensitive || visited >= 400 || depth > 24) return
            visited++
            if (node.isPassword) { sensitive = true; return }
            val value = "${node.text ?: ""} ${node.contentDescription ?: ""}".lowercase()
            if (sensitiveTerms.any(value::contains)) { sensitive = true; return }
            for (index in 0 until node.childCount) {
                if (sensitive || visited >= 400) break
                val child = node.getChild(index) ?: continue
                try { visit(child, depth + 1) } finally { child.recycle() }
            }
        }
        visit(root, 0)
        return sensitive
    }

    fun getUiEventSequence(): Long = uiEventSequence

    /**
     * Waits for a real accessibility event instead of repeatedly traversing
     * the UI tree. The caller still verifies the resulting tree afterwards.
     */
    fun waitForUiEvent(afterSequence: Long, timeoutMs: Long): Long {
        val timeout = timeoutMs.coerceIn(0L, 2_000L)
        uiEventLock.lock()
        try {
            if (uiEventSequence <= afterSequence && timeout > 0L) {
                try {
                    uiEventChanged.await(timeout, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
            return uiEventSequence
        } finally {
            uiEventLock.unlock()
        }
    }

    override fun onInterrupt() {
        // Required override
    }

    /** Keep the display awake during an explicitly started Lucy task. */
    @Synchronized
    fun keepScreenAwake(enabled: Boolean): Boolean {
        val manager = getSystemService(android.content.Context.WINDOW_SERVICE) as WindowManager
        if (!enabled) {
            var released = true
            val existing = keepAwakeView
            if (existing != null) {
                try {
                    manager.removeView(existing)
                } catch (error: Exception) {
                    Log.w(TAG, "Could not release keep-awake overlay", error)
                    released = false
                } finally {
                    keepAwakeView = null
                }
            }
            val wakeLock = screenWakeLock
            if (wakeLock != null) {
                try {
                    if (wakeLock.isHeld) wakeLock.release()
                } catch (error: Exception) {
                    Log.w(TAG, "Could not release screen wake lock", error)
                    released = false
                } finally {
                    screenWakeLock = null
                }
            }
            return released
        }

        // Never wake or interact with a locked device. The user must unlock it.
        if (isDeviceLocked()) {
            Log.i(TAG, "Not waking or keeping the display awake while the device is locked")
            return false
        }

        return try {
            if (screenWakeLock?.isHeld != true) {
                val powerManager = getSystemService(POWER_SERVICE) as PowerManager
                @Suppress("DEPRECATION")
                val wakeLock = powerManager.newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                        PowerManager.ACQUIRE_CAUSES_WAKEUP or
                        PowerManager.ON_AFTER_RELEASE,
                    "$packageName:LucyTaskScreen"
                )
                wakeLock.setReferenceCounted(false)
                // Hard ceiling: even a crashed Flutter task cannot hold this
                // deprecated screen wake lock for longer than 15 minutes.
                wakeLock.acquire(15 * 60 * 1000L)
                screenWakeLock = wakeLock
            }

            if (keepAwakeView == null) {
                val view = View(this)
                val params = WindowManager.LayoutParams(
                    1,
                    1,
                    WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
                    PixelFormat.TRANSLUCENT
                )
                manager.addView(view, params)
                keepAwakeView = view
            }
            true
        } catch (error: Exception) {
            Log.w(TAG, "Could not acquire task-scoped screen wake lock/overlay", error)
            // Roll back a partially acquired wake lock if overlay creation failed.
            val wakeLock = screenWakeLock
            if (wakeLock?.isHeld == true) {
                try { wakeLock.release() } catch (_: Exception) { }
            }
            screenWakeLock = null
            false
        }
    }

    /**
     * Dispatch a gesture and wait for completion (up to 2 seconds).
     * Returns true if completed, false if cancelled or timed out.
     */
    fun isDeviceLocked(): Boolean {
        val keyguard = getSystemService(KEYGUARD_SERVICE) as KeyguardManager
        return keyguard.isKeyguardLocked
    }

    private fun dispatchGestureSync(gesture: GestureDescription): Boolean {
        if (isDeviceLocked()) {
            Log.i(TAG, "Ignoring screen gesture while the device is locked")
            return false
        }
        val latch = CountDownLatch(1)
        var success = false

        val dispatched = dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                super.onCompleted(gestureDescription)
                success = true
                latch.countDown()
            }

            override fun onCancelled(gestureDescription: GestureDescription?) {
                super.onCancelled(gestureDescription)
                Log.w(TAG, "Gesture was cancelled")
                success = false
                latch.countDown()
            }
        }, null)

        if (!dispatched) {
            Log.e(TAG, "dispatchGesture returned false — gesture not dispatched")
            return false
        }

        // Wait up to 2 seconds for the gesture to complete
        latch.await(2, TimeUnit.SECONDS)
        return success
    }

    fun performTap(x: Float, y: Float): Boolean {
        Log.d(TAG, "performTap($x, $y)")
        val path = Path()
        path.moveTo(x, y)

        val gestureBuilder = GestureDescription.Builder()
        gestureBuilder.addStroke(GestureDescription.StrokeDescription(path, 0, 100))

        return dispatchGestureSync(gestureBuilder.build())
    }

    fun performType(text: String): Boolean {
        if (isDeviceLocked()) return false
        val rootNode = rootInActiveWindow ?: return false
        val focusedNode = findFocusedEditText(rootNode)

        if (focusedNode != null) {
            val arguments = Bundle()
            arguments.putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                text
            )
            val changed = focusedNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
            focusedNode.recycle()
            rootNode.recycle()
            return changed
        }
        rootNode.recycle()
        return false
    }

    private fun findFocusedEditText(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isFocused && node.isEditable) {
            return node
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val result = findFocusedEditText(child)
            if (result != null) return result
            child.recycle()
        }
        return null
    }

    fun performSwipe(startX: Float, startY: Float, endX: Float, endY: Float, durationMs: Long = 300): Boolean {
        Log.d(TAG, "performSwipe($startX, $startY -> $endX, $endY)")
        val path = Path()
        path.moveTo(startX, startY)
        path.lineTo(endX, endY)

        val gestureBuilder = GestureDescription.Builder()
        gestureBuilder.addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))

        return dispatchGestureSync(gestureBuilder.build())
    }

    fun pressBack(): Boolean {
        if (isDeviceLocked()) return false
        return performGlobalAction(GLOBAL_ACTION_BACK)
    }

    fun pressHome(): Boolean {
        if (isDeviceLocked()) return false
        return performGlobalAction(GLOBAL_ACTION_HOME)
    }

    /**
     * Executes a small, ordered batch in one MethodChannel call. Only reversible
     * UI primitives are accepted; the Flutter controller applies its local
     * approval policy before dispatching this native batch.
     */
    fun performBatch(actionsJson: String): String {
        val results = JSONArray()
        val actions = try {
            JSONArray(actionsJson)
        } catch (error: Exception) {
            return JSONObject().put("success", false)
                .put("error", "invalid_batch").put("results", results).toString()
        }
        if (actions.length() !in 1..5) {
            return JSONObject().put("success", false)
                .put("error", "batch_size_out_of_range")
                .put("results", results).toString()
        }
        if (isDeviceLocked()) {
            return JSONObject().put("success", false)
                .put("locked", true).put("results", results).toString()
        }

        var batchSuccess = true
        var stoppedAt = -1
        for (index in 0 until actions.length()) {
            if (isDeviceLocked()) {
                batchSuccess = false
                stoppedAt = index
                break
            }
            val item = actions.optJSONObject(index)
            if (item == null) {
                batchSuccess = false
                stoppedAt = index
                results.put(JSONObject().put("success", false).put("error", "invalid_action"))
                break
            }

            val type = item.optString("type", "")
            val eventBaseline = getUiEventSequence()
            val actionSuccess = try {
                when (type) {
                    "tap" -> {
                        val elementId = item.optInt("element", -1)
                        val tree = JSONObject(getUITree())
                        val elements = tree.optJSONArray("elements") ?: JSONArray()
                        var tapped = false
                        for (elementIndex in 0 until elements.length()) {
                            val element = elements.optJSONObject(elementIndex) ?: continue
                            if (element.optInt("id", -2) == elementId) {
                                val bounds = element.optJSONObject("bounds")
                                if (bounds != null) {
                                    tapped = performTap(
                                        bounds.optDouble("cx").toFloat(),
                                        bounds.optDouble("cy").toFloat()
                                    )
                                }
                                break
                            }
                        }
                        tapped
                    }
                    "type" -> performType(item.optString("text", ""))
                    "swipe" -> performSwipe(
                        item.optDouble("startX").toFloat(),
                        item.optDouble("startY").toFloat(),
                        item.optDouble("endX").toFloat(),
                        item.optDouble("endY").toFloat(),
                        item.optLong("durationMs", 250L).coerceIn(100L, 800L)
                    )
                    "back" -> pressBack()
                    "wait" -> {
                        Thread.sleep(item.optLong("ms", 150L).coerceIn(0L, 1000L))
                        true
                    }
                    else -> false
                }
            } catch (error: Exception) {
                Log.w(TAG, "Batch action $index failed", error)
                false
            }

            val outcome = JSONObject().apply {
                put("index", index)
                put("type", type)
                put("success", actionSuccess)
            }
            val expect = item.optJSONObject("expect")
            var expectationMatched = true
            if (actionSuccess && expect != null) {
                waitForUiEvent(eventBaseline, 450L)
                val treeText = getUITree()
                val tree = JSONObject(treeText)
                val expectedPackage = expect.optString("package", "")
                val expectedText = expect.optString("text_contains", "")
                if (expectedPackage.isNotEmpty() &&
                    tree.optString("package") != expectedPackage
                ) expectationMatched = false
                if (expectedText.isNotEmpty() &&
                    !treeText.contains(expectedText, ignoreCase = true)
                ) expectationMatched = false
                outcome.put("expectationMatched", expectationMatched)
            }
            results.put(outcome)

            if (!actionSuccess || !expectationMatched) {
                batchSuccess = false
                stoppedAt = index
                break
            }
        }

        return JSONObject().apply {
            put("success", batchSuccess)
            put("stoppedAt", stoppedAt)
            put("completed", results.length())
            put("results", results)
            put("finalTree", getUITree())
        }.toString()
    }

    private data class ScrollSnapshot(
        val signature: String,
        val texts: List<String>,
        val scrollNode: AccessibilityNodeInfo?
    )

    /**
     * Scrolls the largest visible scroll container until two consecutive
     * visible-content signatures are unchanged, or maxScrolls is reached.
     * This method is invoked from a worker thread by MainActivity.
     */
    fun scrollScreen(forward: Boolean, maxScrolls: Int = 80, collect: Boolean = false): String {
        if (isDeviceLocked()) {
            return JSONObject().apply {
                put("scrolls", 0)
                put("reachedEnd", false)
                put("locked", true)
                put("limited", false)
                put("items", JSONArray())
            }.toString()
        }

        cancelDeepScroll = false
        val limit = maxScrolls.coerceIn(1, 120)
        val collected = LinkedHashSet<String>()
        val initial = captureScrollSnapshot(collect)
        if (initial.signature.isEmpty() && initial.scrollNode == null) {
            return JSONObject().apply {
                put("scrolls", 0)
                put("reachedEnd", false)
                put("limited", false)
                put("dispatchFailed", true)
                put("noAccessibilityTree", true)
                put("items", JSONArray())
            }.toString()
        }
        var current = initial
        if (collect) addCollected(collected, current.texts)

        var scrolls = 0
        var unchangedChecks = 0
        var reachedEnd = false
        var dispatchFailed = false
        val verificationUnavailable = initial.signature.isEmpty()
        val display = resources.displayMetrics
        val width = display.widthPixels.toFloat()
        val height = display.heightPixels.toFloat()

        try {
            while (scrolls < limit && !isDeviceLocked() && !cancelDeepScroll) {
                val target = current.scrollNode
                var moved = false
                var gestureFallbackAllowed = target == null
                if (target != null) {
                    val direction = if (forward) {
                        AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                    } else {
                        AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                    }
                    try {
                        val actionIsExposed = target.actionList.any { it.id == direction }
                        gestureFallbackAllowed = !actionIsExposed
                        if (actionIsExposed) {
                            moved = target.performAction(direction)
                        }
                    } catch (error: Exception) {
                        Log.w(TAG, "Accessibility scroll action failed", error)
                        gestureFallbackAllowed = true
                    } finally {
                        target.recycle()
                        current = current.copy(scrollNode = null)
                    }
                }

                // Only gesture-fallback when the node does not expose the
                // directional action. A supported action returning false is
                // usually an edge-of-list signal; swiping there can trigger
                // pull-to-refresh instead of proving the boundary.
                if (!moved && gestureFallbackAllowed) {
                    val startY = if (forward) height * 0.75f else height * 0.25f
                    val endY = if (forward) height * 0.25f else height * 0.75f
                    moved = try {
                        performSwipe(width * 0.5f, startY, width * 0.5f, endY, 250L)
                    } catch (error: Exception) {
                        Log.w(TAG, "Scroll gesture fallback failed", error)
                        false
                    }
                }

                if (!moved && !gestureFallbackAllowed) {
                    scrolls++
                    val boundaryCheck = captureScrollSnapshot(collect)
                    if (collect) addCollected(collected, boundaryCheck.texts)
                    if (boundaryCheck.signature.isNotEmpty() &&
                        boundaryCheck.signature == current.signature
                    ) {
                        unchangedChecks++
                    } else {
                        unchangedChecks = 0
                    }
                    current = boundaryCheck
                    if (unchangedChecks >= 2) {
                        reachedEnd = true
                        break
                    }
                    continue
                }

                if (!moved) {
                    dispatchFailed = true
                    break
                }

                scrolls++
                // Accessibility events are not guaranteed for every app. A short
                // bounded settle period keeps this deterministic without polling.
                try {
                    Thread.sleep(300L)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                }

                val next = captureScrollSnapshot(collect)
                if (collect) addCollected(collected, next.texts)

                if (next.signature.isNotEmpty() &&
                    next.signature == current.signature
                ) {
                    unchangedChecks++
                } else {
                    unchangedChecks = 0
                }

                current = next
                if (unchangedChecks >= 2) {
                    reachedEnd = true
                    break
                }
            }
        } finally {
            current.scrollNode?.recycle()
        }

        val items = JSONArray()
        if (collect) {
            collected.forEach { items.put(it) }
        }
        return JSONObject().apply {
            put("scrolls", scrolls)
            put("reachedEnd", reachedEnd)
            put("limited", !reachedEnd && scrolls >= limit)
            put("dispatchFailed", dispatchFailed)
            put("verificationUnavailable", verificationUnavailable)
            put("locked", isDeviceLocked())
            put("cancelled", cancelDeepScroll)
            put("forward", forward)
            put("items", items)
        }.toString()
    }

    private fun addCollected(target: LinkedHashSet<String>, values: List<String>) {
        for (value in values) {
            if (target.size >= 400) break
            val normalized = value.trim().replace(Regex("\\s+"), " ").take(200)
            if (normalized.isNotEmpty()) target.add(normalized)
        }
    }

    /**
     * Captures visible text in traversal order and returns a copy of the
     * largest visible scrollable node by on-screen bounds area.
     */
    private fun captureScrollSnapshot(collect: Boolean): ScrollSnapshot {
        val root = rootInActiveWindow
        if (root == null) {
            return ScrollSnapshot("", emptyList(), null)
        }

        val visibleTexts = ArrayList<String>()
        val signatureParts = ArrayList<String>()
        var largestScrollable: AccessibilityNodeInfo? = null
        var largestArea = 0L
        var visited = 0
        val maxNodes = 400
        val maxDepth = 28

        fun visit(node: AccessibilityNodeInfo, depth: Int) {
            if (visited >= maxNodes || depth > maxDepth) return
            visited++

            if (node.isVisibleToUser && !node.isPassword) {
                val text = node.text?.toString()?.trim().orEmpty()
                val desc = node.contentDescription?.toString()?.trim().orEmpty()
                val nodeBounds = Rect()
                node.getBoundsInScreen(nodeBounds)
                val verticalPosition = "${nodeBounds.top}:${nodeBounds.bottom}"
                if (text.isNotEmpty()) {
                    val value = text.take(200)
                    signatureParts.add("t:$value@$verticalPosition")
                    if (collect && visibleTexts.size < 400) visibleTexts.add(value)
                }
                if (desc.isNotEmpty() && desc != text) {
                    val value = desc.take(200)
                    signatureParts.add("d:$value@$verticalPosition")
                    if (collect && visibleTexts.size < 400) visibleTexts.add(value)
                }

                if (node.isScrollable) {
                    val bounds = Rect()
                    node.getBoundsInScreen(bounds)
                    val area = bounds.width().toLong().coerceAtLeast(0L) *
                        bounds.height().toLong().coerceAtLeast(0L)
                    if (area > largestArea) {
                        largestScrollable?.recycle()
                        largestScrollable = AccessibilityNodeInfo.obtain(node)
                        largestArea = area
                    }
                }
            }

            for (index in 0 until node.childCount) {
                if (visited >= maxNodes) break
                val child = node.getChild(index) ?: continue
                try {
                    visit(child, depth + 1)
                } finally {
                    child.recycle()
                }
            }
        }

        try {
            visit(root, 0)
        } catch (error: Exception) {
            Log.w(TAG, "Could not fully inspect scroll container", error)
        } finally {
            root.recycle()
        }

        val signature = signatureParts.joinToString("|")
        return ScrollSnapshot(signature, visibleTexts, largestScrollable)
    }

    /**
     * Harvest the accessibility tree of the current foreground app.
     * Returns a compact JSON string containing only useful interactive/text elements.
     * Uses multiple windows for better coverage when the active window is sparse.
     * Limits: max ~200 elements, max depth ~20.
     */
    fun getUITree(): String {
        if (isDeviceLocked()) {
            return JSONObject().apply {
                put("package", "locked")
                put("locked", true)
                put("elements", JSONArray())
            }.toString()
        }
        val elements = JSONArray()
        var elementCount = 0
        val maxElements = 200
        val maxDepth = 20

        fun traverseInternal(
            node: AccessibilityNodeInfo,
            depth: Int,
            clickableAncestor: Boolean
        ) {
            if (elementCount >= maxElements || depth > maxDepth) return

            val bounds = Rect()
            node.getBoundsInScreen(bounds)

            // Password fields remain represented only by the boolean marker;
            // never export their text or content description to the model.
            val text = if (isPassword) null else node.text?.toString()
            val contentDesc = if (isPassword) null else node.contentDescription?.toString()
            val isClickable = node.isClickable || clickableAncestor
            val isEditable = node.isEditable
            val isPassword = node.isPassword
            val isCheckable = node.isCheckable
            val isScrollable = node.isScrollable
            val isVisible = node.isVisibleToUser
            val isFocused = node.isFocused
            val isFocusable = node.isFocusable
            val isLongClickable = node.isLongClickable

            // Include elements that are useful:
            // - have text or description (semantic content), OR
            // - are interactive (clickable, editable, checkable, scrollable, focusable)
            val isUseful = isVisible && (
                !text.isNullOrBlank() ||
                !contentDesc.isNullOrBlank() ||
                isClickable ||
                isEditable ||
                isCheckable ||
                isScrollable ||
                isLongClickable
            )

            if (isUseful && bounds.width() > 0 && bounds.height() > 0) {
                val className = node.className?.toString()?.substringAfterLast('.') ?: "View"

                val element = JSONObject().apply {
                    put("id", elementCount)
                    put("type", className)
                    node.viewIdResourceName?.let { put("resourceId", it) }
                    if (!text.isNullOrBlank()) put("text", text)
                    if (!contentDesc.isNullOrBlank()) put("desc", contentDesc)
                    if (isClickable) put("clickable", true)
                    if (isEditable) put("editable", true)
                    if (isPassword) put("password", true)
                    if (isFocused) put("focused", true)
                    if (isCheckable) {
                        put("checkable", true)
                        put("checked", node.isChecked)
                    }
                    if (isScrollable) put("scrollable", true)
                    if (isLongClickable) put("longClickable", true)
                    if (isFocusable) put("focusable", true)
                    put("bounds", JSONObject().apply {
                        put("cx", bounds.centerX())
                        put("cy", bounds.centerY())
                        put("w", bounds.width())
                        put("h", bounds.height())
                    })
                }
                elements.put(element)
                elementCount++
            }

            // Traverse children
            for (i in 0 until node.childCount) {
                if (elementCount >= maxElements) break
                val child = node.getChild(i) ?: continue
                traverseInternal(child, depth + 1, isClickable)
                child.recycle()
            }
        }

        fun traverse(node: AccessibilityNodeInfo, depth: Int) {
            traverseInternal(node, depth, false)
        }

        // Try rootInActiveWindow first
        var rootNode = rootInActiveWindow
        val packageName: String

        if (rootNode != null) {
            packageName = rootNode.packageName?.toString() ?: "unknown"
            val rootChildCount = rootNode.childCount

            try {
                traverse(rootNode, 0)
            } catch (e: Exception) {
                Log.e(TAG, "getUITree: error traversing active window tree", e)
            } finally {
                rootNode.recycle()
            }

            // If the active window gave a sparse tree, try other windows too.
            // This can happen when apps use multiple windows (e.g., split views,
            // dialogs over content, or custom window layers).
            if (elementCount <= 3) {
                Log.d(TAG, "getUITree: sparse tree from active window ($elementCount elements, rootChildCount=$rootChildCount), trying all windows")
                try {
                    val allWindows = windows
                    for (window in allWindows) {
                        if (elementCount >= maxElements) break
                        // Focus on application windows — skip system UI, input method, etc.
                        if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION &&
                            window.type != AccessibilityWindowInfo.TYPE_SYSTEM
                        ) continue
                        val windowRoot = window.root ?: continue
                        // Skip if this is the same window we already traversed
                        val windowPkg = windowRoot.packageName?.toString()
                        if (windowPkg == packageName && rootChildCount > 0) {
                            windowRoot.recycle()
                            continue
                        }
                        try {
                            traverse(windowRoot, 0)
                        } catch (e: Exception) {
                            Log.w(TAG, "getUITree: error traversing window $windowPkg", e)
                        } finally {
                            windowRoot.recycle()
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "getUITree: windows fallback failed", e)
                }
            }
        } else {
            Log.w(TAG, "getUITree: rootInActiveWindow is null, trying windows list")
            packageName = tryGetPackageFromWindows(elements, ::traverse) ?: "unknown"
        }

        val appVersionCode = try {
            if (packageName.isNotBlank() && packageName != "unknown") {
                val packageInfo = packageManager.getPackageInfo(packageName, 0)
                if (android.os.Build.VERSION.SDK_INT >= 28) {
                    packageInfo.longVersionCode.toString()
                } else {
                    packageInfo.versionCode.toString()
                }
            } else {
                "unknown"
            }
        } catch (_: Exception) {
            "unknown"
        }
        val result = JSONObject().apply {
            put("package", packageName)
            put("appVersionCode", appVersionCode)
            put("elements", elements)
        }

        Log.d(TAG, "getUITree: package=$packageName, elements=$elementCount")
        return result.toString()
    }

    /**
     * Fallback: when rootInActiveWindow is null, try to find the app window
     * from the windows list. Returns the package name if found.
     */
    private fun tryGetPackageFromWindows(
        elements: JSONArray,
        traverse: (AccessibilityNodeInfo, Int) -> Unit
    ): String? {
        try {
            val allWindows = windows
            for (window in allWindows) {
                if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION &&
                            window.type != AccessibilityWindowInfo.TYPE_SYSTEM
                        ) continue
                val root = window.root ?: continue
                val pkg = root.packageName?.toString()
                try {
                    traverse(root, 0)
                } catch (e: Exception) {
                    Log.w(TAG, "tryGetPackageFromWindows: error traversing $pkg", e)
                } finally {
                    root.recycle()
                }
                if (pkg != null) return pkg
            }
        } catch (e: Exception) {
            Log.w(TAG, "tryGetPackageFromWindows: failed", e)
        }
        return null
    }

    override fun onDestroy() {
        cancelDeepScroll = true
        watcherHandler.removeCallbacks(watcherRunnable)
        keepScreenAwake(false)
        super.onDestroy()
        instance = null
    }
}
