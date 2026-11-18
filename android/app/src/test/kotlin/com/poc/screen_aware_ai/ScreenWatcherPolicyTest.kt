package com.poc.screen_aware_ai

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenWatcherPolicyTest {
    @Test
    fun recognizesExplicitAdSkipLabels() {
        assertTrue(ScreenWatcherPolicy.isAdSkipLabel("Skip"))
        assertTrue(ScreenWatcherPolicy.isAdSkipLabel(" Skip Ad "))
        assertTrue(ScreenWatcherPolicy.isAdSkipLabel("SKIP ADS"))
        assertFalse(ScreenWatcherPolicy.isAdSkipLabel("Skip intro"))
        assertFalse(ScreenWatcherPolicy.isAdSkipLabel("Continue"))
    }

    @Test
    fun recognizesSafePopupChoicesInSupportedLanguages() {
        listOf(
            "Not now", "Maybe later", "No thanks", "Dismiss", "Got it",
            "Reject all", "अभी नहीं", "बाद में", "ठीक है",
            "ಈಗ ಬೇಡ", "ನಂತರ", "ಸರಿ", "今はしない", "後で",
            "ليس الآن", "لا شكرًا"
        ).forEach { assertTrue("Expected safe label: $it", ScreenWatcherPolicy.isSafeDismissLabel(it)) }
        assertFalse(ScreenWatcherPolicy.isSafeDismissLabel("Allow"))
        assertFalse(ScreenWatcherPolicy.isSafeDismissLabel("Accept all"))
        assertFalse(ScreenWatcherPolicy.isSafeDismissLabel("Buy now"))
        assertFalse(ScreenWatcherPolicy.isSafeDismissLabel("Delete"))
    }

    @Test
    fun closeButtonNeedsPopupContainerAtCallSite() {
        assertTrue(ScreenWatcherPolicy.isCloseControl("app:id/dialog_close", emptyList()))
        assertTrue(ScreenWatcherPolicy.isCloseControl("", listOf("Close")))
        assertFalse(ScreenWatcherPolicy.isCloseControl("", listOf("Open")))
    }
}
