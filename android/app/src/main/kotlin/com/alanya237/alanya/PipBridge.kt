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
    private var activity: Activity? = null

    /** Un appel vidéo est en cours : quitter l'application doit passer en PiP. */
    private var eligible = false

    private val supported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O

    /** L'auto-entrée, qui couvre tous les chemins de sortie, demande l'API 31. */
    private val autoEnterSupported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    fun attach(messenger: BinaryMessenger, activity: Activity) {
        this.activity = activity
        channel = MethodChannel(messenger, CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setEligible" -> {
                        eligible = call.argument<Boolean>("eligible") ?: false
                        Log.d(TAG, "éligible=$eligible")
                        appliquerParametres()
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
        // Sans remettre les paramètres : `detach` est appelée depuis `onDestroy`,
        // où l'activité n'accepte plus rien. L'éligibilité meurt avec elle.
        activity = null
        eligible = false
    }

    /**
     * Déclare à Android que l'activité doit basculer d'elle-même en vignette.
     *
     * `onUserLeaveHint` ne couvre que le bouton Accueil. Le retour arrière ne
     * passe pas par lui — il *termine* l'activité — pas plus que la vue des
     * applications récentes. L'appel vidéo mourait donc avec l'activité, et la
     * première image livrée après le détachement du moteur Flutter emportait le
     * processus (« FlutterJNI is not attached to native »).
     *
     * `setAutoEnterEnabled` renverse la charge : c'est le système qui ouvre la
     * vignette dès que l'activité passerait en arrière-plan, quel que soit le
     * chemin emprunté. En dessous de l'API 31, le relais est pris par
     * `onUserLeaveHint` pour l'Accueil et par `SystemPip.didPopRoute` côté
     * Flutter pour le retour arrière.
     */
    private fun appliquerParametres() {
        if (!autoEnterSupported) return
        val act = activity ?: return
        try {
            act.setPictureInPictureParams(construireParams(autoEnter = eligible))
        } catch (e: IllegalStateException) {
            Log.w(TAG, "auto-entrée en PiP refusée: ${e.message}")
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "paramètres de PiP refusés: ${e.message}")
        }
    }

    private fun construireParams(autoEnter: Boolean): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            // 16:9 : le format d'une vidéo d'appel. Android borne de toute
            // façon le ratio entre 1:2.39 et 2.39:1 et refuse au-delà.
            .setAspectRatio(Rational(16, 9))
        if (autoEnterSupported) builder.setAutoEnterEnabled(autoEnter)
        return builder.build()
    }

    /**
     * Bouton Accueil ou geste de sortie, l'activité étant encore au premier
     * plan. Sans auto-entrée, c'est le seul moment où Android accepte d'ouvrir
     * un PiP : passé `onPause`, `enterPictureInPictureMode` est refusé.
     *
     * Tous les chemins de sortie ne passent pas par ici — ni le retour arrière,
     * ni la vue des applications récentes. Sur API 31+, `setAutoEnterEnabled` a
     * déjà tout couvert et cet appel ne fait que devancer le système ; en
     * dessous, le retour arrière est rattrapé côté Flutter.
     */
    fun onUserLeaveHint(activity: Activity) {
        if (!eligible) return
        enterPip(activity)
    }

    private fun enterPip(activity: Activity): Boolean {
        if (!supported) return false
        if (activity.isInPictureInPictureMode) return true
        return try {
            activity.enterPictureInPictureMode(construireParams(autoEnter = eligible))
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
