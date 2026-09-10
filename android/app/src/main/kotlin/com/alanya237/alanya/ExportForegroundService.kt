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
 * Maintient l'application vivante pendant l'assemblage d'une archive d'export.
 *
 * ── Pourquoi il est nécessaire ──
 *
 * Un export peut porter sur plusieurs gigaoctets de photos et de vidéos.
 * L'inscrit ne va pas rester à regarder une barre de progression : il va
 * basculer sur autre chose. Sans service de premier plan, Android suspend puis
 * tue le processus, et l'archive à moitié écrite est perdue.
 *
 * ── La limite de six heures d'Android 15 ──
 *
 * Les services de type `dataSync` sont plafonnés à six heures par tranche de
 * 24 h pour les applications ciblant l'API 35 ou plus — ce qui est le cas
 * d'Alanya. Au terme, le système appelle [onTimeout] et laisse quelques
 * secondes pour s'arrêter ; passé ce délai il lève une exception fatale.
 *
 * Ce n'est pas une contrainte pour nous : l'assemblage est local au disque et
 * dure des minutes, pas des heures. Et le compteur repart quand l'inscrit
 * ramène l'application au premier plan — ce qui est précisément le cas d'un
 * export qu'il vient de lancer. [onTimeout] est implémenté par prudence, pour
 * que le cas extrême produise un arrêt propre plutôt qu'un plantage.
 */
class ExportForegroundService : Service() {

    companion object {
        private const val TAG = "ExportFGS"
        private const val CHANNEL_ID = "alanya_export"
        private const val CHANNEL_NAME = "Exportation en cours"
        private const val NOTIFICATION_ID = 4211

        private const val EXTRA_PROGRESS = "progress"
        private const val EXTRA_TOTAL = "total"

        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, ExportForegroundService::class.java),
            )
        }

        /** Met à jour la notification sans redémarrer le service. */
        fun update(context: Context, done: Int, total: Int) {
            val intent = Intent(context, ExportForegroundService::class.java)
                .putExtra(EXTRA_PROGRESS, done)
                .putExtra(EXTRA_TOTAL, total)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ExportForegroundService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        val done = intent?.getIntExtra(EXTRA_PROGRESS, 0) ?: 0
        val total = intent?.getIntExtra(EXTRA_TOTAL, 0) ?: 0
        try {
            startAsForeground(buildNotification(done, total))
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed", e)
            stopSelf()
        }
        // NOT_STICKY : si le système nous tue, il ne doit PAS nous relancer
        // tout seul. L'export a été demandé par un geste précis ; le rejouer
        // sans que personne l'ait demandé écrirait une archive fantôme.
        return START_NOT_STICKY
    }

    /**
     * Appelé par Android 15+ au terme des six heures cumulées.
     *
     * On dispose de quelques secondes pour appeler [stopSelf]. Ne pas le faire
     * lève `RemoteServiceException` — un plantage, pas un avertissement.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "délai de service dépassé → arrêt propre")
        stopSelf()
    }

    override fun onDestroy() {
        Log.i(TAG, "stopped")
        super.onDestroy()
    }

    private fun startAsForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            // LOW : la notification est obligatoire, l'interruption ne l'est
            // pas. Un export n'a rien d'urgent.
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Progression de l'exportation de vos médias"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        mgr.createNotificationChannel(channel)
    }

    private fun buildNotification(done: Int, total: Int): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(CHANNEL_NAME)
            .setSmallIcon(R.drawable.ic_stat_notification)
            .setColor(ContextCompat.getColor(this, R.color.notification_accent))
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setSilent(true)

        if (total > 0) {
            builder.setContentText("$done / $total")
            builder.setProgress(total, done, false)
        } else {
            // Total encore inconnu : barre indéterminée plutôt qu'un « 0 / 0 »
            // qui donnerait l'impression que rien n'avance.
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }
}
