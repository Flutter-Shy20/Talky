package com.alanya237.alanya

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Pont Flutter → [SecureStorageRepair]
 * Canal : `com.alanya237.alanya/secure_storage_repair` (repair).
 *
 * Filet de sécurité pour le cas résiduel que la sonde de démarrage ne peut pas
 * couvrir : le Keystore invalidé *pendant* que l'app tourne (ajout ou retrait
 * du verrouillage d'écran). Voir [SecureStorageRepair.repairNow] pour les
 * limites — la session en cours reste en mode dégradé, la purge effective a
 * lieu au prochain démarrage.
 */
object SecureStorageBridge {
    private const val TAG = "SecureStorageBridge"
    private const val CHANNEL = "com.alanya237.alanya/secure_storage_repair"

    fun attach(messenger: BinaryMessenger, context: Context) {
        val appCtx = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "repair" -> {
                    try {
                        result.success(SecureStorageRepair.repairNow(appCtx))
                    } catch (e: Exception) {
                        Log.e(TAG, "repair failed", e)
                        result.error("repair_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
