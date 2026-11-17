package com.poc.screen_aware_ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LucyContactMatcherTest {
    private val papa = LucyContactCandidate("1", "Papa", "+911111111111", "mobile")
    private val mom = LucyContactCandidate("2", "Amma", "+922222222222", "mobile")
    private val friend = LucyContactCandidate("3", "Asha Rao", "+933333333333", "home")

    @Test
    fun matchesCommonSpeechSpellingAndRepeatedLetters() {
        val matches = LucyContactMatcher.bestMatches(
            "call to my pappa",
            listOf(papa, mom, friend)
        )

        assertEquals(listOf(papa), matches)
    }

    @Test
    fun understandsRelationshipAliasesWithoutInventingANumber() {
        assertEquals(
            listOf(mom),
            LucyContactMatcher.bestMatches("call my mother", listOf(papa, mom, friend))
        )
    }

    @Test
    fun returnsAmbiguousCandidatesInsteadOfGuessing() {
        val secondPapa = LucyContactCandidate("4", "Papa", "+944444444444", "home")
        val matches = LucyContactMatcher.bestMatches("papa", listOf(papa, secondPapa))

        assertEquals(2, matches.size)
        assertTrue(matches.all { it.name == "Papa" })
    }

    @Test
    fun doesNotReturnAnUnrelatedContact() {
        assertTrue(LucyContactMatcher.bestMatches("pappa", listOf(friend)).isEmpty())
    }

    @Test
    fun matchesMinorNameSpellingErrors() {
        assertEquals(
            listOf(friend),
            LucyContactMatcher.bestMatches("Asha Rwo", listOf(papa, mom, friend))
        )
    }
}
