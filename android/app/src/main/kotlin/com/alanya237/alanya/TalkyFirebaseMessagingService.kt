package com.alanya237.alanya

import android.app.ActivityManager
import android.app.KeyguardManager
import android.content.Context
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugins.firebase.messaging.ContextHolder

/**
 * Couche Android propriétaire (Phase 4) — activée via manifest placeholder
 * `talkyNotificationNativeV2=true`.
 *
 * Messages : MessagingStyle natif. Appels / meetings : traités par Flutter.
 *
 * **Ce service ne transmet rien à Flutter, et n'a pas à le faire.** Le plugin
 * `firebase_messaging` déclare son propre `FlutterFirebaseMessagingReceiver`
 * sur `com.google.android.c2dm.intent.RECEIVE` — une diffusion distincte de
 * celle qui nous amène ici. Ce receiver reçoit donc *chaque* message de son
 * côté et fait déjà tout le travail : `LiveData` au premier plan,
 * `enqueueMessageProcessing` en arrière-plan, et la mise en réserve des
 * messages à bloc `notification` qui alimente `getInitialMessage` et
 * `onMessageOpenedApp`.
 *
 * Un `forwardToFlutter` reproduisait exactement ce chemin : le handler Dart
 * s'exécutait deux fois. Au premier plan, `qr_contact_scanned` ouvrait ainsi
 * **deux fois** la boîte « ajouter en retour », et une notification générique
 * alertait deux fois sur un même identifiant.
 */
class TalkyFirebaseMessagingService : FirebaseMessagingService() {

    override fun onMessageReceived(message: RemoteMessage) {
        ensureFlutterContext()

        val data = message.data
        // Sans type, rien de natif à faire : le receiver Flutter a déjà pris
        // le message en charge de son côté.
        val type = data["type"] ?: return

        when (type) {
            "message" -> {
                // Accusé de remise AVANT tout court-circuit : la notification
                // peut être supprimée (conversation déjà ouverte) ou silencieuse
                // (sourdine), l'expéditeur doit voir ses 2 coches dans tous les cas.
                DeliveryAckHelper.enqueueAndPost(this, data["conversationId"], data["msgID"])

                if (data["silent"] == "1") {
                    Log.d(TAG, "message silencieux (sourdine) conv=${data["conversationId"]} — accusé seul")
                    return
                }
                if (MessageNotificationHelper.shouldSuppress(this, data)) {
                    Log.d(TAG, "message suppressed (active conv)")
                    return
                }
                Log.d(TAG, "message native show conv=${data["conversationId"]} msgID=${data["msgID"]}")
                MessageNotificationHelper.showMessage(this, data)
            }
            "message_read_sync" -> {
                val convId = data["conversationId"]?.toIntOrNull() ?: return
                MessageNotificationHelper.cancelConversation(this, convId)
            }
            "call", "group_call" -> {
                if (isApplicationForeground(this)) {
                    // Premier plan : Flutter + socket (IncomingCallScreen + sonnerie).
                    // Le receiver a déjà posté le message dans la LiveData.
                    Log.d(TAG, "call foreground → Flutter callId=${data["callId"] ?: data["roomId"]}")
                } else {
                    Log.d(TAG, "call native show callId=${data["callId"] ?: data["roomId"]}")
                    CallIncomingHelper.showIncoming(this, data)
                }
            }
            "call_ended" -> {
                Log.d(TAG, "call native end callId=${data["callId"]}")
                CallIncomingHelper.endCall(this, data)
            }
            // meeting_invite, meeting_reminder, status_view, qr_contact_scanned,
            // broadcast… : rien de natif, le receiver Flutter s'en charge seul.
            else -> Unit
        }
    }

    override fun onNewToken(token: String) {
        Log.d(TAG, "onNewToken — Flutter syncTokenWithBackend expected")
    }

    private fun ensureFlutterContext() {
        if (ContextHolder.getApplicationContext() == null) {
            ContextHolder.setApplicationContext(applicationContext)
        }
    }

    /** Copie de la logique FlutterFirebaseMessagingUtils (classe package-private). */
    private fun isApplicationForeground(context: Context): Boolean {
        val keyguardManager =
            context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (keyguardManager?.isKeyguardLocked == true) return false

        val activityManager =
            context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return false
        val processes = activityManager.runningAppProcesses ?: return false
        val packageName = context.packageName
        for (process in processes) {
            if (process.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND &&
                process.processName == packageName
            ) {
                return true
            }
        }
        return false
    }

    companion object {
        private const val TAG = "TalkyFcmService"
    }
}
