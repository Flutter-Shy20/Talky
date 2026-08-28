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
 * Foreground service micro (± caméra) pendant un appel VoIP.
 * Requis Android 14+ pour conserver l'accès capture en arrière-plan
 * (distinct du FGS CallKit phoneCall).
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

    override fun onDestroy() {
        Log.i(TAG, "stopped")
        super.onDestroy()
    }

    private fun startAsForeground(notification: Notification, isVideo: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification)
            return
        }

        // Le type CAMERA était déclaré dès que l'appel était vidéo. Or un appel
        // vidéo tourne légitimement sans permission caméra : `WebRTCService.init`
        // se contente d'un journal et continue en audio. Sur Android 14+,
        // `startForeground` refuse alors un type dont la permission manque, la
        // levée était rattrapée, et le service s'arrêtait — emportant avec lui
        // le type MICROPHONE. Le micro se coupait donc dès le passage en
        // arrière-plan, pour un appel qui n'avait rien demandé de tel.
        val cameraAutorisee = ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.CAMERA,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED

        val avecCamera = isVideo && cameraAutorisee
        if (isVideo && !cameraAutorisee) {
            Log.w(TAG, "appel vidéo sans permission caméra — FGS micro seul")
        }

        val type = if (avecCamera) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        } else {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }

        try {
            startForeground(NOTIFICATION_ID, notification, type)
        } catch (e: Exception) {
            // Deuxième filet : mieux vaut le micro seul que pas de service du
            // tout. Un appel vidéo dont la caméra ne suit pas reste un appel.
            if (!avecCamera) throw e
            Log.w(TAG, "startForeground(micro+caméra) refusé (${e.message}) — repli micro seul")
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        }
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
