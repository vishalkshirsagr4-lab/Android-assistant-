package com.poc.screen_aware_ai

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.Rect
import android.graphics.PixelFormat
import android.os.Bundle
import android.os.PowerManager
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

class ScreenActionService : AccessibilityService() {

    companion object {
        var instance: ScreenActionService? = null
        private const val TAG = "ScreenActionService"
    }

    private var keepAwakeView: View? = null
    private var screenWakeLock: PowerManager.WakeLock? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.d(TAG, "Accessibility service connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // We don't need to process events for this PoC
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

        val limit = maxScrolls.coerceIn(1, 120)
        val collected = LinkedHashSet<String>()
        val initial = captureScrollSnapshot(collect)
        var current = initial
        if (collect) addCollected(collected, current.texts)

        var scrolls = 0
        var unchangedChecks = 0
        var reachedEnd = false
        var dispatchFailed = false
        val display = resources.displayMetrics
        val width = display.widthPixels.toFloat()
        val height = display.heightPixels.toFloat()

        try {
            while (scrolls < limit && !isDeviceLocked()) {
                val target = current.scrollNode
                var moved = false
                if (target != null) {
                    val direction = if (forward) {
                        AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                    } else {
                        AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                    }
                    try {
                        moved = target.performAction(direction)
                    } catch (error: Exception) {
                        Log.w(TAG, "Accessibility scroll action failed; trying gesture fallback", error)
                    } finally {
                        target.recycle()
                    }
                }

                // WebViews and some custom lists expose no working scroll action.
                if (!moved) {
                    val startY = if (forward) height * 0.75f else height * 0.25f
                    val endY = if (forward) height * 0.25f else height * 0.75f
                    moved = try {
                        performSwipe(width * 0.5f, startY, width * 0.5f, endY, 250L)
                    } catch (error: Exception) {
                        Log.w(TAG, "Scroll gesture fallback failed", error)
                        false
                    }
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

                if (next.signature == current.signature) {
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
            put("locked", isDeviceLocked())
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

            if (node.isVisibleToUser) {
                val text = node.text?.toString()?.trim().orEmpty()
                val desc = node.contentDescription?.toString()?.trim().orEmpty()
                if (text.isNotEmpty()) {
                    val value = text.take(200)
                    signatureParts.add("t:$value")
                    if (collect && visibleTexts.size < 400) visibleTexts.add(value)
                }
                if (desc.isNotEmpty() && desc != text) {
                    val value = desc.take(200)
                    signatureParts.add("d:$value")
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

        val signature = signatureParts.joinToString("|").hashCode().toString()
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

        fun traverse(node: AccessibilityNodeInfo, depth: Int) {
            if (elementCount >= maxElements || depth > maxDepth) return

            val bounds = Rect()
            node.getBoundsInScreen(bounds)

            val text = node.text?.toString()
            val contentDesc = node.contentDescription?.toString()
            val isClickable = node.isClickable
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
                traverse(child, depth + 1)
                child.recycle()
            }
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

        val result = JSONObject().apply {
            put("package", packageName)
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
        keepScreenAwake(false)
        super.onDestroy()
        instance = null
    }
}
