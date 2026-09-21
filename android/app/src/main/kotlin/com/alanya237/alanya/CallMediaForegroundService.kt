package com.alanya237.alanya

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
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
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_HANG_UP_LABEL = "hangUpLabel"
        const val EXTRA_CHANNEL_NAME = "channelName"

        /** Instant de référence du chronomètre, en millisecondes epoch. */
        const val EXTRA_STARTED_AT = "startedAt"

        /**
         * Le chronomètre doit-il tourner ?
         *
         * La règle est tenue et éprouvée côté Dart
         * (`callNotificationUsesChronometer`) : tant que l'appel sonne, aucune
         * durée, sinon elle compterait la sonnerie. Ce service obéit, il ne la
         * redérive pas — deux copies d'une même règle finissent par diverger.
         */
        const val EXTRA_USES_CHRONOMETER = "usesChronometer"

        const val ACTION_HANG_UP = "com.alanya237.alanya.CALL_HANG_UP"

        /**
         * Démarre ou **met à jour** la notification.
         *
         * Relancer un service déjà lancé ne le duplique pas : `onStartCommand`
         * est simplement rappelé, et la notification se réécrit sous le même
         * identifiant. C'est ainsi que le chronomètre apparaît au moment où
         * l'appel se connecte, sans second service ni seconde notification.
         */
        fun start(
            context: Context,
            isVideo: Boolean,
            title: String?,
            body: String?,
            hangUpLabel: String?,
            channelName: String?,
            startedAt: Long,
            usesChronometer: Boolean,
        ) {
            val intent = Intent(context, CallMediaForegroundService::class.java).apply {
                putExtra(EXTRA_IS_VIDEO, isVideo)
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_BODY, body)
                putExtra(EXTRA_HANG_UP_LABEL, hangUpLabel)
                putExtra(EXTRA_CHANNEL_NAME, channelName)
                putExtra(EXTRA_STARTED_AT, startedAt)
                putExtra(EXTRA_USES_CHRONOMETER, usesChronometer)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CallMediaForegroundService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_HANG_UP) {
            // L'utilisateur a appuyé sur « Raccrocher » depuis la notification.
            // On prévient Flutter, qui soldera l'appel auprès du pair et du
            // serveur, et on s'arrête sans l'attendre : quelqu'un qui appuie
            // sur « Raccrocher » doit voir la notification disparaître, même si
            // l'isolate ne répond plus. Le pair, lui, reste couvert par la
            // grâce de déconnexion du serveur.
            Log.i(TAG, "raccrochage demandé depuis la notification")
            CallMediaBridge.notifyHangUpRequested()
            stopSelf()
            return START_NOT_STICKY
        }

        val isVideo = intent?.getBooleanExtra(EXTRA_IS_VIDEO, false) ?: false
        val channelName = intent?.getStringExtra(EXTRA_CHANNEL_NAME)
        val title = intent?.getStringExtra(EXTRA_TITLE)
        val body = intent?.getStringExtra(EXTRA_BODY)
        val hangUpLabel = intent?.getStringExtra(EXTRA_HANG_UP_LABEL)
        val startedAt = intent?.getLongExtra(EXTRA_STARTED_AT, 0L) ?: 0L
        val chrono = intent?.getBooleanExtra(EXTRA_USES_CHRONOMETER, false) ?: false
        try {
            ensureChannel(channelName)
            val notification =
                buildNotification(title, body, hangUpLabel, startedAt, chrono)
            startAsForeground(notification, isVideo)
            Log.i(TAG, "started isVideo=$isVideo chrono=$chrono")
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
     * ce service. Sa notification, posée en `setOngoing(true)`, n'est pas
     * balayable : l'utilisateur gardait un « Appel en cours » qu'il ne pouvait
     * pas retirer, et un processus maintenu à priorité premier plan, jusqu'au
     * prochain appel mené à son terme ou à un arrêt forcé. Le bouton
     * « Raccrocher » ne sauverait rien ici : son intention remonte à un isolate
     * Dart que le retrait de la tâche vient de tuer.
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

    private fun ensureChannel(channelName: String?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java) ?: return
        // Pas de sortie anticipée quand le canal existe déjà :
        // `createNotificationChannel` met à jour le nom d'un canal connu, et
        // c'est le seul moyen de faire suivre la langue choisie dans
        // l'application à qui l'a installée avant. Seules l'importance et la
        // sonnerie sont figées après création, et ni l'une ni l'autre ne
        // changent ici.
        val channel = NotificationChannel(
            CHANNEL_ID,
            channelName?.takeIf { it.isNotBlank() } ?: CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Maintient le micro actif pendant un appel"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        mgr.createNotificationChannel(channel)
    }

    /**
     * Elle disait « Appel en cours · Alanya », sans qui, sans depuis quand, et
     * sans moyen d'agir. Depuis qu'elle est la seule notification de l'appel,
     * elle doit porter ce que portait celle du plugin.
     *
     * Pourquoi pas `CallStyle` : il remplace le titre et le texte par des
     * libellés fournis par le système, traduits dans la langue de l'appareil.
     * Alanya a sa propre langue, qui peut en différer — un téléphone en anglais
     * réglé sur Alanya en français afficherait « Ongoing call ». Le style
     * ordinaire garde nos chaînes.
     */
    private fun buildNotification(
        title: String?,
        body: String?,
        hangUpLabel: String?,
        startedAt: Long,
        usesChronometer: Boolean,
    ): Notification {
        val ouvrir = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val raccrocher = PendingIntent.getService(
            this,
            1,
            Intent(this, CallMediaForegroundService::class.java).setAction(ACTION_HANG_UP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title?.takeIf { it.isNotBlank() } ?: CHANNEL_NAME)
            .setContentText(body.orEmpty())
            .setSmallIcon(R.drawable.ic_stat_notification)
            .setColor(ContextCompat.getColor(this, R.color.notification_accent))
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setSilent(true)
            .apply {
                if (ouvrir != null) setContentIntent(ouvrir)
                if (usesChronometer) {
                    setWhen(startedAt)
                    setShowWhen(true)
                    setUsesChronometer(true)
                } else {
                    setShowWhen(false)
                }
                if (!hangUpLabel.isNullOrBlank()) {
                    addAction(0, hangUpLabel, raccrocher)
                }
            }
            .build()
    }
}
