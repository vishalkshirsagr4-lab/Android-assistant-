package com.poc.screen_aware_ai

import java.text.Normalizer
import java.util.Locale

internal data class LucyContactCandidate(
    val contactId: String,
    val name: String,
    val phoneNumber: String,
    val typeLabel: String
)

/**
 * Local-only, conservative contact-name matching for imperfect speech transcripts.
 * It never chooses between equally plausible contacts; callers must ask the
 * user to disambiguate those results.
 */
internal object LucyContactMatcher {
    private const val MINIMUM_MATCH_SCORE = 0.72
    private const val AMBIGUITY_MARGIN = 0.08
    private const val MAX_MATCHES = 5

    private val leadingCommandWords = setOf(
        "call", "phone", "dial", "contact", "please", "to", "my", "the",
        "number", "message", "text", "send"
    )

    fun bestMatches(
        query: String,
        candidates: List<LucyContactCandidate>
    ): List<LucyContactCandidate> {
        val normalizedQuery = normalizeQuery(query)
        if (normalizedQuery.isBlank()) return emptyList()

        val ranked = candidates
            .filter { it.name.isNotBlank() && it.phoneNumber.isNotBlank() }
            .distinctBy { "${it.contactId}|${it.phoneNumber.filter(Char::isDigit)}" }
            .map { candidate ->
                candidate to similarity(normalizedQuery, normalizeName(candidate.name))
            }
            .filter { it.second >= MINIMUM_MATCH_SCORE }
            .sortedByDescending { it.second }

        val bestScore = ranked.firstOrNull()?.second ?: return emptyList()
        return ranked
            .filter { bestScore - it.second <= AMBIGUITY_MARGIN }
            .take(MAX_MATCHES)
            .map { it.first }
    }

    internal fun normalizeQuery(value: String): String {
        val tokens = normalizeRaw(value).split(' ').filter { it.isNotBlank() }.toMutableList()
        while (tokens.isNotEmpty() && tokens.first() in leadingCommandWords) {
            tokens.removeAt(0)
        }
        return tokens.joinToString(" ") { canonicalToken(collapseRepeatedLetters(it)) }
    }

    internal fun normalizeName(value: String): String =
        normalizeRaw(value).split(' ')
            .filter { it.isNotBlank() }
            .joinToString(" ") { canonicalToken(collapseRepeatedLetters(it)) }

    private fun normalizeRaw(value: String): String {
        val withoutMarks = Normalizer.normalize(value.lowercase(Locale.ROOT), Normalizer.Form.NFD)
            .replace(Regex("\\p{Mn}+"), "")
        return withoutMarks
            .replace(Regex("[^\\p{L}\\p{N}]+"), " ")
            .trim()
            .replace(Regex("\\s+"), " ")
    }

    private fun collapseRepeatedLetters(value: String): String =
        value.replace(Regex("([\\p{L}])\\1+"), "$1")

    private fun canonicalToken(value: String): String = when (value) {
        "papa", "pappa", "appa", "dad", "daddy", "father", "baba", "bapu" -> "father"
        "mom", "mommy", "mother", "mummy", "amma", "mamma" -> "mother"
        "bro", "brother", "bhai" -> "brother"
        "sis", "sister", "akka" -> "sister"
        else -> value
    }

    private fun similarity(query: String, candidate: String): Double {
        if (query == candidate) return 1.0
        val candidateTokens = candidate.split(' ').filter { it.isNotBlank() }
        val fullScore = levenshteinSimilarity(query, candidate)
        val tokenScore = candidateTokens.maxOfOrNull { levenshteinSimilarity(query, it) } ?: 0.0
        return maxOf(fullScore, tokenScore)
    }

    private fun levenshteinSimilarity(left: String, right: String): Double {
        if (left == right) return 1.0
        if (left.isEmpty() || right.isEmpty()) return 0.0
        val previous = IntArray(right.length + 1) { it }
        val current = IntArray(right.length + 1)
        for (i in left.indices) {
            current[0] = i + 1
            for (j in right.indices) {
                val substitutionCost = if (left[i] == right[j]) 0 else 1
                current[j + 1] = minOf(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + substitutionCost
                )
            }
            for (j in previous.indices) previous[j] = current[j]
        }
        val distance = previous[right.length]
        return 1.0 - distance.toDouble() / maxOf(left.length, right.length)
    }
}
