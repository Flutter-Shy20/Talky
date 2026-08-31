package com.alanya237.alanya

import android.app.Activity
import android.app.PictureInPictureParams
import android.os.Build
import android.util.Log
import android.util.Rational
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Picture-in-Picture système pendant un appel vidéo.
 * Canal : `com.alanya237.alanya/pip`.
 *
 * Flutter → natif : `setEligible` dit si un appel vidéo est en cours, donc si
 * quitter l'application doit ouvrir une fenêtre plutôt que de tout masquer.
 * `enterNow` force l'entrée (bouton dédié, si un jour il en faut un).
 *
 * Natif → Flutter : `onPipModeChanged` prévient des deux transitions. Elle est
 * indispensable et pas seulement informative — en PiP, l'activité est **en
 * pause tout en restant visible**, si bien que Flutter ne peut pas déduire
 * l'état du seul cycle de vie. C'est ce qui décide du sort de la caméra
 * (`localVideoShouldPause`) et du passage à une disposition réduite.
 *
 * Le PiP demande l'API 26 ; l'application accepte l'API 23. En dessous, tout
 * ici est inerte et l'appel se comporte comme avant.
 */
object PipBridge {
    private const val TAG = "PipBridge"
    private const val CHANNEL = "com.alanya237.alanya/pip"

    private var channel: MethodChannel? = null

    /** Un appel vidéo est en cours : quitter l'application doit passer en PiP. */
    private var eligible = false

    private val supported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O

    fun attach(messenger: BinaryMessenger, activity: Activity) {
        channel = MethodChannel(messenger, CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setEligible" -> {
                        eligible = call.argument<Boolean>("eligible") ?: false
                        Log.d(TAG, "éligible=$eligible")
                        result.success(supported)
                    }
                    "enterNow" -> result.success(enterPip(activity))
                    "isSupported" -> result.success(supported)
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        eligible = false
    }

    /**
     * Bouton Accueil ou geste de sortie, l'activité étant encore au premier
     * plan. C'est le seul moment où Android accepte d'ouvrir un PiP : passé
     * `onPause`, `enterPictureInPictureMode` est refusé.
     *
     * Tous les chemins de sortie ne passent pas par ici — la vue des
     * applications récentes, notamment, n'appelle pas `onUserLeaveHint`. Un
     * appel non converti en PiP retombe simplement sur le comportement
     * d'arrière-plan ordinaire.
     */
    fun onUserLeaveHint(activity: Activity) {
        if (!eligible) return
        enterPip(activity)
    }

    private fun enterPip(activity: Activity): Boolean {
        if (!supported) return false
        if (activity.isInPictureInPictureMode) return true
        return try {
            val params = PictureInPictureParams.Builder()
                // 16:9 : le format d'une vidéo d'appel. Android borne de toute
                // façon le ratio entre 1:2.39 et 2.39:1 et refuse au-delà.
                .setAspectRatio(Rational(16, 9))
                .build()
            activity.enterPictureInPictureMode(params)
        } catch (e: IllegalStateException) {
            // Appareil ou profil où le PiP est désactivé, activité déjà en
            // pause : l'appel continue, sans fenêtre.
            Log.w(TAG, "entrée en PiP refusée: ${e.message}")
            false
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "paramètres de PiP refusés: ${e.message}")
            false
        }
    }

    /** Prévient Flutter des deux transitions, entrée comme sortie. */
    fun notifyModeChanged(inPipMode: Boolean) {
        Log.d(TAG, "mode PiP=$inPipMode")
        channel?.invokeMethod("onPipModeChanged", inPipMode)
    }
}
