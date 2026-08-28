package com.alanya237.alanya

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Parties pures de [AvatarCache] : rien ici ne touche au disque, au réseau ni à
 * `android.graphics` — donc tout tourne en JVM, comme [NativeHttpPolicyTest].
 */
class AvatarCacheTest {

    private val jour = 24L * 60 * 60 * 1000

    // ── cacheKey ─────────────────────────────────────────────────────────

    @Test
    fun `la cle est stable et sensible a l'URL`() {
        val a = "https://www.alanya237.com/uploads/images/a.jpg"
        val b = "https://www.alanya237.com/uploads/images/b.jpg"
        assertEquals(AvatarCache.cacheKey(a), AvatarCache.cacheKey(a))
        assertNotEquals(AvatarCache.cacheKey(a), AvatarCache.cacheKey(b))
    }

    @Test
    fun `la cle ignore les espaces de bord`() {
        val url = "https://www.alanya237.com/uploads/images/a.jpg"
        assertEquals(AvatarCache.cacheKey(url), AvatarCache.cacheKey("  $url  "))
    }

    @Test
    fun `la cle est un nom de fichier utilisable`() {
        val key = AvatarCache.cacheKey("https://www.alanya237.com/uploads/images/a.jpg")
        // SHA-256 en hexadécimal : 64 caractères, aucun séparateur de chemin.
        assertEquals(64, key.length)
        assertTrue(key.all { it in '0'..'9' || it in 'a'..'f' })
    }

    // ── sampleSize ───────────────────────────────────────────────────────

    @Test
    fun `une image deja petite n'est pas sous-echantillonnee`() {
        assertEquals(1, AvatarCache.sampleSize(256, 256))
        assertEquals(1, AvatarCache.sampleSize(100, 100))
    }

    @Test
    fun `le facteur reste une puissance de deux qui ne passe pas sous la cible`() {
        // 1024 → /2 = 512 (≥ 256), /4 = 256 (≥ 256), /8 = 128 : on s'arrête à 4.
        assertEquals(4, AvatarCache.sampleSize(1024, 1024))
        assertEquals(8, AvatarCache.sampleSize(4000, 3000))

        for ((w, h) in listOf(1024 to 1024, 4000 to 3000, 2048 to 512, 333 to 999)) {
            val sample = AvatarCache.sampleSize(w, h)
            assertTrue("puissance de deux", sample > 0 && (sample and (sample - 1)) == 0)
            assertTrue(
                "ne descend pas sous la cible",
                minOf(w, h) / sample >= AvatarCache.TARGET_PX / 2,
            )
        }
    }

    @Test
    fun `des bornes absurdes ne font pas diviser par zero`() {
        assertEquals(1, AvatarCache.sampleSize(0, 0))
        assertEquals(1, AvatarCache.sampleSize(-10, 200))
        assertEquals(1, AvatarCache.sampleSize(200, 200, target = 0))
    }

    // ── evictionVictims ──────────────────────────────────────────────────

    @Test
    fun `un cache jeune et petit ne perd rien`() {
        val now = 1_000_000_000L
        val entries = (1..5).map { AvatarCache.Entry("f$it", now - it * 1000L) }
        assertTrue(AvatarCache.evictionVictims(entries, now).isEmpty())
    }

    @Test
    fun `les entrees perimees partent`() {
        val now = 30L * jour
        val entries = listOf(
            AvatarCache.Entry("vieux", now - 8 * jour),
            AvatarCache.Entry("recent", now - 1 * jour),
        )
        assertEquals(listOf("vieux"), AvatarCache.evictionVictims(entries, now))
    }

    @Test
    fun `au-dela du plafond, les plus anciennes partent d'abord`() {
        val now = 30L * jour
        // 5 entrées fraîches, plafond à 3 → les 2 plus anciennes sautent.
        val entries = (1..5).map { AvatarCache.Entry("f$it", now - it * 1000L) }
        val victims = AvatarCache.evictionVictims(entries, now, maxEntries = 3)
        assertEquals(2, victims.size)
        assertTrue(victims.containsAll(listOf("f5", "f4")))
    }

    @Test
    fun `peremption et plafond se cumulent sans doublon`() {
        val now = 30L * jour
        val entries = listOf(
            AvatarCache.Entry("perime", now - 10 * jour),
            AvatarCache.Entry("a", now - 3000L),
            AvatarCache.Entry("b", now - 2000L),
            AvatarCache.Entry("c", now - 1000L),
        )
        val victims = AvatarCache.evictionVictims(entries, now, maxEntries = 2)
        // Le périmé, plus la plus ancienne des trois restantes.
        assertEquals(listOf("perime", "a"), victims)
        assertEquals(victims.size, victims.toSet().size)
    }
}
