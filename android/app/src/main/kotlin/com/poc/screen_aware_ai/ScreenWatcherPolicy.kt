package com.poc.screen_aware_ai

/**
 * Pure label matching for the conservative ScreenWatcher.
 *
 * Only explicit ad-skip labels and non-destructive popup choices are eligible.
 * Cookie consent is reject-only: Lucy never silently opts a user into tracking.
 */
internal object ScreenWatcherPolicy {
    private val adSkipLabels = setOf(
        "skip", "skip ad", "skip ads", "close ad"
    )

    private val safeDismissLabels = setOf(
        "not now", "maybe later", "no thanks", "dismiss", "got it",
        "reject all", "reject",
        "अभी नहीं", "बाद में", "नहीं धन्यवाद", "धन्यवाद नहीं", "ठीक है",
        "ಈಗ ಬೇಡ", "ನಂತರ", "ಬೇಡ ಧನ್ಯವಾದ", "ಸರಿ",
        "今はしない", "後で", "結構です", "了解",
        "ليس الآن", "ربما لاحقًا", "لا شكرًا", "حسنًا", "رفض الكل"
    )

    private val closeLabels = setOf("close", "close dialog", "close popup", "×", "x")

    fun normalize(value: String): String =
        value.trim().lowercase().replace(Regex("\\s+"), " ")

    fun isAdSkipLabel(label: String): Boolean =
        normalize(label) in adSkipLabels

    fun isSafeDismissLabel(label: String): Boolean =
        normalize(label) in safeDismissLabels

    fun isCloseControl(viewId: String, labels: List<String>): Boolean {
        val id = viewId.lowercase()
        return labels.any { normalize(it) in closeLabels } ||
            id.endsWith("close_button") ||
            id.endsWith("dialog_close") ||
            id.endsWith("popup_close")
    }
}
