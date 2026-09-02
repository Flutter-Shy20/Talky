package com.alanya237.alanya

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Service au premier plan pendant un appel VoIP.
 *
 * Déclarait `microphone` et, en vidéo, `camera`. Ces deux types sont soumis aux
 * restrictions « while-in-use » : depuis Android 14, `startForeground` lève une
 * `SecurityException` si l'application est en arrière-plan. C'est exactement le
 * décrochage depuis une notification, application fermée — le cas qui compte le
 * plus.
 *
 * `phoneCall` en est exempté. Il ne demande aucune permission d'exécution,
 * seulement `MANAGE_OWN_CALLS` au manifeste, déjà déclarée. Tout le calcul de
 * type, la vérification de la permission caméra et le repli « micro seul »
 * disparaissent avec.
 *
 * L'exemption d'accès au micro en arrière-plan vaut pour les applications VoIP
 * **qui utilisent les API Telecom**. C'est le cas depuis la montée du plugin en
 * 3.1.5 : il enregistre un `PhoneAccount` auto-géré et déclare chaque appel à
 * Telecom, entrant comme sortant.
 */
class CallMediaForegroundService : Service() {

    companion object {
        private const val TAG = "CallMediaFGS"
        private const val CHANNEL_ID = "alanya_call_media"
        private const val CHANNEL_NAME = "Appel en cours"
        private const val NOTIFICATION_ID = 23701
        const val EXTRA_IS_VIDEO = "isVideo"

        fun start(context: Context, isVideo: Boolean) {
            val intent = Intent(context, CallMediaForegroundService::class.java).apply {
                putExtra(EXTRA_IS_VIDEO, isVideo)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CallMediaForegroundService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val isVideo = intent?.getBooleanExtra(EXTRA_IS_VIDEO, false) ?: false
        try {
            ensureChannel()
            val notification = buildNotification()
            startAsForeground(notification, isVideo)
            Log.i(TAG, "started isVideo=$isVideo")
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed", e)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    /**
     * L'utilisateur a balayé Alanya depuis les récents.
     *
     * Android n'arrête PAS un service au retrait de sa tâche : l'activité et son
     * moteur Flutter sont détruits, l'isolate Dart meurt, et plus personne ne
     * peut appeler `stop` sur le canal `call_media` — le seul chemin d'arrêt de
     * ce service. Sa notification, posée en `setOngoing(true)` et sans action,
     * n'est pas balayable : l'utilisateur gardait un « Appel en cours » qu'il ne
     * pouvait pas retirer, et un processus maintenu à priorité premier plan,
     * jusqu'au prochain appel mené à son terme ou à un arrêt forcé.
     *
     * Au relancement, rien ne nettoyait l'orphelin non plus : le drapeau côté
     * Dart repart à faux, donc l'arrêt sort d'entrée.
     *
     * Le pair, lui, est prévenu par la grâce de déconnexion du serveur.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "tâche retirée des récents — arrêt du service")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (e: Exception) {
            Log.w(TAG, "stopForeground: $e")
        }
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        Log.i(TAG, "stopped")
        super.onDestroy()
    }

    private fun startAsForeground(notification: Notification, isVideo: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification)
            return
        }
        Log.i(TAG, "startForeground(phoneCall) isVideo=$isVideo")
        startForeground(
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL,
        )
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Maintient le micro actif pendant un appel"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        mgr.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(CHANNEL_NAME)
            .setContentText("Alanya")
            .setSmallIcon(R.drawable.ic_stat_notification)
            .setColor(ContextCompat.getColor(this, R.color.notification_accent))
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setSilent(true)
            .build()
    }
}
