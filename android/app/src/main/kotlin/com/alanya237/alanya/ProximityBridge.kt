package com.alanya237.alanya

import android.content.Context
import android.os.PowerManager
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Extinction de l'écran à l'approche du visage, pendant un appel.
 * Canal : `com.alanya237.alanya/proximity` (enable / disable).
 *
 * Android sait déjà le faire : `PROXIMITY_SCREEN_OFF_WAKE_LOCK` confie au
 * système l'écoute du capteur, l'extinction et le rallumage. Rien à faire côté
 * Flutter — pas d'abonnement à un flux de valeurs, pas de seuil à choisir, pas
 * de course entre l'événement et le rendu. C'est aussi le seul moyen d'éteindre
 * l'écran sans permission particulière : une application ne peut pas décider
 * seule d'éteindre l'écran, mais elle peut demander ce verrou-là.
 *
 * `WAKE_LOCK` est déjà déclarée au manifeste pour le wakelock vidéo.
 */
object ProximityBridge {
    private const val TAG = "ProximityBridge"
    private const val CHANNEL = "com.alanya237.alanya/proximity"
    private const val LOCK_TAG = "alanya:call_proximity"

    private var wakeLock: PowerManager.WakeLock? = null

    fun attach(messenger: BinaryMessenger, context: Context) {
        val appCtx = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enable" -> {
                    try {
                        result.success(enable(appCtx))
                    } catch (e: Exception) {
                        Log.e(TAG, "enable failed", e)
                        result.error("enable_failed", e.message, null)
                    }
                }
                "disable" -> {
                    try {
                        disable()
                        result.success(null)
                    } catch (e: Exception) {
                        Log.e(TAG, "disable failed", e)
                        result.error("disable_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * @return false si l'appareil ne sait pas éteindre l'écran par proximité —
     *         capteur absent, ou niveau de verrou non pris en charge. L'appel
     *         doit continuer normalement dans ce cas, sans extinction.
     */
    private fun enable(context: Context): Boolean {
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        if (pm == null) {
            Log.w(TAG, "PowerManager indisponible")
            return false
        }

        if (!pm.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
            Log.w(TAG, "PROXIMITY_SCREEN_OFF_WAKE_LOCK non supporté sur cet appareil")
            return false
        }

        val existing = wakeLock
        if (existing != null && existing.isHeld) return true

        @Suppress("DEPRECATION")
        val lock = existing ?: pm.newWakeLock(
            PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
            LOCK_TAG,
        ).also { wakeLock = it }

        // Sans référence comptée : `disable` doit relâcher au premier appel,
        // quel que soit le nombre de fois où la route audio a été réévaluée.
        lock.setReferenceCounted(false)
        lock.acquire()
        Log.d(TAG, "Verrou de proximité acquis")
        return true
    }

    /**
     * Idempotent, et sûr à appeler sur un verrou jamais acquis : c'est la fin
     * d'appel qui l'invoque, y compris quand [enable] a renvoyé false.
     */
    fun disable() {
        val lock = wakeLock ?: return
        if (lock.isHeld) {
            lock.release()
            Log.d(TAG, "Verrou de proximité relâché")
        }
        wakeLock = null
    }
}
