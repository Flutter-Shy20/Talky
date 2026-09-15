package com.alanya237.alanya

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Shader
import android.util.Log
import androidx.core.graphics.drawable.IconCompat
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Cache disque des photos de profil affichées dans les notifications.
 *
 * Deux contraintes dictent toute la forme de ce fichier.
 *
 * 1. **Ne jamais faire attendre la notification.** `onMessageReceived` est
 *    synchrone, sans scope coroutine, et poste l'accusé de remise juste avant
 *    l'affichage : y bloquer sur le réseau retarderait aussi cet accusé. Le
 *    téléchargement part donc sur un executor, et la notification est réécrite
 *    ensuite (`setOnlyAlertOnce`), exactement comme après une réponse rapide.
 *
 * 2. **Borner la taille du bitmap.** Les extras d'une notification traversent
 *    une transaction Binder plafonnée à ~1 Mo *partagée par le processus*. Une
 *    photo pleine résolution dans `Person.setIcon` ne dégrade pas l'affichage :
 *    elle lève `TransactionTooLargeException` et fait tomber TOUTES les
 *    notifications du processus. D'où le sous-échantillonnage au décodage puis
 *    le cadrage à [TARGET_PX].
 *
 * Toute défaillance — réseau, URL invalide, disque plein — se solde par un
 * `null` : l'appelant affiche alors la notification sans photo, c'est-à-dire
 * comme avant l'existence de ce cache.
 */
object AvatarCache {

    private const val TAG = "TalkyAvatarCache"
    private const val DIR = "notif-avatars"

    /** Côté du bitmap final. Au-delà, on paie du Binder pour des pixels invisibles. */
    const val TARGET_PX = 256

    private const val CONNECT_TIMEOUT_MS = 3000
    private const val READ_TIMEOUT_MS = 3000

    /** Un avatar plus lourd que ça est une anomalie : on abandonne plutôt que de le lire. */
    private const val MAX_DOWNLOAD_BYTES = 4L * 1024 * 1024

    /** Bornes de la purge, appliquées après chaque écriture. */
    private const val MAX_ENTRIES = 200
    private const val MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "avatar-cache").apply { isDaemon = true }
    }

    // ── Parties pures (testées en JVM) ───────────────────────────────────

    /**
     * Nom de fichier dérivé de l'URL. SHA-256 plutôt que `hashCode` : deux URLs
     * d'avatars différentes qui entreraient en collision afficheraient la photo
     * de quelqu'un d'autre — un défaut bien pire qu'une absence de photo.
     */
    fun cacheKey(url: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(url.trim().toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }

    /**
     * Facteur de sous-échantillonnage `BitmapFactory`. Puissance de deux, comme
     * l'exige `inSampleSize` : la plus grande qui laisse l'image au-dessus de
     * [target], pour décoder le moins de pixels possible sans passer sous la
     * taille visée.
     */
    fun sampleSize(srcWidth: Int, srcHeight: Int, target: Int = TARGET_PX): Int {
        if (srcWidth <= 0 || srcHeight <= 0 || target <= 0) return 1
        var sample = 1
        var half = minOf(srcWidth, srcHeight) / 2
        while (half >= target) {
            sample *= 2
            half /= 2
        }
        return sample
    }

    /** Une entrée du cache, réduite à ce dont la purge a besoin. */
    data class Entry(val name: String, val lastModifiedMs: Long)

    /**
     * Quelles entrées supprimer ? Les périmées d'abord, puis les plus anciennes
     * tant que le compte dépasse [maxEntries]. Sans cette purge, `cacheDir`
     * enflerait à chaque nouvel expéditeur croisé.
     */
    fun evictionVictims(
        entries: List<Entry>,
        nowMs: Long,
        maxEntries: Int = MAX_ENTRIES,
        maxAgeMs: Long = MAX_AGE_MS,
    ): List<String> {
        val expired = entries.filter { nowMs - it.lastModifiedMs > maxAgeMs }
        val kept = entries - expired.toSet()
        val surplus = (kept.size - maxEntries).coerceAtLeast(0)
        val oldest = kept.sortedBy { it.lastModifiedMs }.take(surplus)
        return (expired + oldest).map { it.name }
    }

    // ── Accès au cache ───────────────────────────────────────────────────

    private fun dir(context: Context): File =
        File(context.cacheDir, DIR).apply { if (!exists()) mkdirs() }

    /** Fichier déjà en cache pour cette URL, ou `null`. Aucun accès réseau. */
    fun cachedFile(context: Context, url: String?): File? {
        val clean = url?.trim().orEmpty()
        if (clean.isEmpty()) return null
        return try {
            File(dir(context), cacheKey(clean)).takeIf { it.isFile && it.length() > 0 }
        } catch (e: Exception) {
            Log.w(TAG, "cachedFile failed", e)
            null
        }
    }

    /**
     * Bitmap de la photo **si elle est déjà en cache**. Ne déclenche aucun
     * téléchargement : c'est l'appelant qui décide de demander l'enrichissement
     * via [prefetch].
     */
    fun bitmap(context: Context, url: String?): Bitmap? {
        val file = cachedFile(context, url) ?: return null
        return try {
            BitmapFactory.decodeFile(file.absolutePath)
        } catch (e: Exception) {
            Log.w(TAG, "decode failed", e)
            null
        }
    }

    /**
     * Même chose, empaquetée pour `Person.setIcon`.
     *
     * `createWithBitmap` et non `createWithAdaptiveBitmap` : le cadrage
     * circulaire est déjà appliqué à l'écriture, et une icône adaptative
     * rognerait une seconde fois.
     */
    fun icon(context: Context, url: String?): IconCompat? {
        val bitmap = bitmap(context, url) ?: return null
        return try {
            IconCompat.createWithBitmap(bitmap)
        } catch (e: Exception) {
            Log.w(TAG, "icon failed", e)
            null
        }
    }

    /** `true` si au moins une des URLs mérite un téléchargement. */
    fun needsFetch(context: Context, urls: Collection<String>): Boolean =
        urls.any { it.isNotBlank() && cachedFile(context, it) == null }

    /**
     * Télécharge en arrière-plan les URLs absentes du cache, puis appelle
     * [onReady] — une seule fois, et seulement si quelque chose a été mis en
     * cache. Un échec total reste silencieux : la notification déjà postée est
     * la bonne.
     */
    fun prefetch(context: Context, urls: Collection<String>, onReady: () -> Unit) {
        val missing = urls.filter { it.isNotBlank() && cachedFile(context, it) == null }.distinct()
        if (missing.isEmpty()) return

        val appContext = context.applicationContext
        executor.execute {
            var any = false
            for (url in missing) {
                if (download(appContext, url)) any = true
            }
            if (!any) return@execute
            try {
                purge(appContext)
                onReady()
            } catch (e: Exception) {
                Log.e(TAG, "onReady failed", e)
            }
        }
    }

    // ── Téléchargement ───────────────────────────────────────────────────

    private fun download(context: Context, url: String): Boolean {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = READ_TIMEOUT_MS
                requestMethod = "GET"
                instanceFollowRedirects = true
            }
            val code = conn.responseCode
            if (code !in 200..299) {
                Log.d(TAG, "download http=$code")
                return false
            }
            // `contentLength` (Int) et non `contentLengthLong` : ce dernier est
            // API 24, or minSdk descend à 23. Un avatar ne pèse de toute façon
            // pas 2 Go, et la lecture bornée plus bas est le vrai garde-fou.
            val declared = conn.contentLength
            if (declared > MAX_DOWNLOAD_BYTES) {
                Log.d(TAG, "download trop lourd: $declared octets")
                return false
            }

            val bytes = conn.inputStream.use { input ->
                // Lecture bornée : `Content-Length` peut mentir ou manquer.
                val buffer = ByteArray(16 * 1024)
                val out = java.io.ByteArrayOutputStream()
                var total = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > MAX_DOWNLOAD_BYTES) {
                        Log.d(TAG, "download interrompu au-delà de la borne")
                        return false
                    }
                    out.write(buffer, 0, read)
                }
                out.toByteArray()
            }

            val bitmap = decodeScaled(bytes) ?: return false
            val circular = toCircle(bitmap)
            writeAtomically(context, url, circular)
        } catch (e: Exception) {
            Log.d(TAG, "download failed: ${e.message}")
            false
        } finally {
            try { conn?.disconnect() } catch (_: Exception) {}
        }
    }

    /** Décodage en deux passes : bornes d'abord, pixels ensuite. */
    private fun decodeScaled(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight)
        }
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null

        // Recadrage au CENTRE avant mise à l'échelle. Passer directement par
        // `createScaledBitmap(_, TARGET, TARGET, _)` écraserait une photo au
        // format portrait — un visage déformé, pas un visage rogné.
        val side = minOf(decoded.width, decoded.height)
        if (side <= 0) return null
        return try {
            val square = if (decoded.width == decoded.height) {
                decoded
            } else {
                Bitmap.createBitmap(
                    decoded,
                    (decoded.width - side) / 2,
                    (decoded.height - side) / 2,
                    side,
                    side,
                )
            }
            // Le sous-échantillonnage ne donne que des puissances de deux : sans
            // cette dernière réduction, un avatar de 300 px le resterait.
            if (square.width <= TARGET_PX) {
                square
            } else {
                Bitmap.createScaledBitmap(square, TARGET_PX, TARGET_PX, true)
            }
        } catch (e: Exception) {
            Log.w(TAG, "recadrage/échelle échoués", e)
            decoded
        }
    }

    /**
     * Masque circulaire appliqué nous-mêmes plutôt que `createWithAdaptiveBitmap` :
     * une icône adaptative réserve une zone de sécurité (~66 %) et rognerait le
     * visage bien au-delà du cercle attendu.
     */
    private fun toCircle(source: Bitmap): Bitmap {
        val side = minOf(source.width, source.height)
        if (side <= 0) return source
        return try {
            val output = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(output)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = BitmapShader(source, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
            }
            // Recentre si la source n'est pas carrée.
            val left = (source.width - side) / 2f
            val top = (source.height - side) / 2f
            canvas.translate(-left, -top)
            canvas.drawCircle(left + side / 2f, top + side / 2f, side / 2f, paint)
            output
        } catch (e: Exception) {
            Log.w(TAG, "toCircle failed", e)
            source
        }
    }

    /**
     * Écriture via un fichier temporaire puis renommage : un processus tué en
     * plein `compress` laisserait sinon un PNG tronqué que toutes les lectures
     * suivantes prendraient pour un cache valide.
     */
    private fun writeAtomically(context: Context, url: String, bitmap: Bitmap): Boolean {
        val target = File(dir(context), cacheKey(url))
        val temp = File(target.parentFile, "${target.name}.tmp")
        return try {
            FileOutputStream(temp).use { out ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                out.flush()
            }
            if (temp.renameTo(target)) {
                true
            } else {
                temp.delete()
                false
            }
        } catch (e: Exception) {
            Log.w(TAG, "writeAtomically failed", e)
            try { temp.delete() } catch (_: Exception) {}
            false
        }
    }

    private fun purge(context: Context) {
        try {
            val files = dir(context).listFiles()?.filter { it.isFile } ?: return
            val entries = files.map { Entry(it.name, it.lastModified()) }
            val victims = evictionVictims(entries, System.currentTimeMillis()).toSet()
            if (victims.isEmpty()) return
            for (file in files) {
                if (file.name in victims) file.delete()
            }
            Log.d(TAG, "purge ${victims.size} entrées")
        } catch (e: Exception) {
            Log.w(TAG, "purge failed", e)
        }
    }

    /** Réservé aux tests instrumentés / au débogage. */
    fun clear(context: Context) {
        try {
            dir(context).listFiles()?.forEach { it.delete() }
        } catch (e: Exception) {
            Log.w(TAG, "clear failed", e)
        }
    }
}
