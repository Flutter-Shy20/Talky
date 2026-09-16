package com.alanya237.alanya

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Pont entre Flutter et [CallMediaForegroundService].
 * Canal : `com.alanya237.alanya/call_media` (start / stop).
 *
 * Il ne descendait que dans un sens. Depuis que la notification de l'appel
 * porte un bouton « Raccrocher », elle doit pouvoir remonter : sans cela le
 * bouton arrêterait le service sans jamais prévenir le pair ni le serveur.
 */
object CallMediaBridge {
    private const val TAG = "CallMediaBridge"
    private const val CHANNEL = "com.alanya237.alanya/call_media"

    private var channel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger, context: Context) {
        val appCtx = context.applicationContext
        val canal = MethodChannel(messenger, CHANNEL)
        channel = canal
        canal.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val isVideo = call.argument<Boolean>("isVideo") ?: false
                    try {
                        CallMediaForegroundService.start(
                            appCtx,
                            isVideo,
                            call.argument<String>("title"),
                            call.argument<String>("body"),
                            call.argument<String>("hangUpLabel"),
                            call.argument<String>("channelName"),
                            // Dart envoie un entier ; sur 64 bits il arrive en
                            // `Long`, sur 32 en `Int`. `Number` couvre les deux.
                            call.argument<Number>("startedAt")?.toLong() ?: 0L,
                            call.argument<Boolean>("usesChronometer") ?: false,
                        )
                        result.success(null)
                    } catch (e: Exception) {
                        Log.e(TAG, "start failed", e)
                        result.error("start_failed", e.message, null)
                    }
                }
                "stop" -> {
                    try {
                        CallMediaForegroundService.stop(appCtx)
                        result.success(null)
                    } catch (e: Exception) {
                        Log.e(TAG, "stop failed", e)
                        result.error("stop_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * « Raccrocher » a été pressé depuis la notification.
     *
     * Appelé depuis `onStartCommand`, donc déjà sur le fil principal ; le
     * `post` garde la garantie si l'appelant change un jour, car un canal de
     * méthode n'accepte d'être invoqué que de là.
     *
     * Silencieux quand personne n'écoute : l'application a pu être balayée des
     * récents, auquel cas le service s'est déjà arrêté seul.
     */
    fun notifyHangUpRequested() {
        val canal = channel ?: return
        Handler(Looper.getMainLooper()).post {
            try {
                canal.invokeMethod("onHangUpRequested", null)
            } catch (e: Exception) {
                Log.w(TAG, "notifyHangUpRequested: ${e.message}")
            }
        }
    }
}
