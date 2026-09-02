package com.alanya237.alanya

import android.content.Context
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import org.json.JSONArray
import org.json.JSONObject
import com.hiennv.flutter_callkit_incoming.CallkitConstants
import com.hiennv.flutter_callkit_incoming.CallkitNotificationManager
import com.hiennv.flutter_callkit_incoming.CallkitNotificationService
import com.hiennv.flutter_callkit_incoming.CallkitSoundPlayerManager
import com.hiennv.flutter_callkit_incoming.Data
import com.hiennv.flutter_callkit_incoming.addCall
import com.hiennv.flutter_callkit_incoming.getDataActiveCalls
import com.hiennv.flutter_callkit_incoming.removeAllCalls
import com.hiennv.flutter_callkit_incoming.removeCall

/**
 * Affiche CallKit / plein écran sans isolate Flutter (app tuée).
 * Le BroadcastReceiver du plugin exige une instance plugin initialisée ;
 * on instancie directement [CallkitNotificationManager] au démarrage app.
 */
object CallIncomingHelper {

    private const val TAG = "TalkyCallIncoming"

    private var notificationManager: CallkitNotificationManager? = null
    private var soundManager: CallkitSoundPlayerManager? = null
    private var lastShownCallId: String? = null

    fun ensureInitialized(context: Context) {
        if (notificationManager != null) return
        val appContext = context.applicationContext
        soundManager = CallkitSoundPlayerManager(appContext)
        notificationManager = CallkitNotificationManager(appContext, soundManager!!)
        Log.d(TAG, "CallkitNotificationManager ready")
    }

    fun showIncoming(context: Context, data: Map<String, String>) {
        val callId = (data["callId"] ?: data["roomId"] ?: "").trim()
        if (callId.isNotEmpty() && callId == lastShownCallId) {
            Log.d(TAG, "skip duplicate callId=$callId")
            return
        }

        // ── Cet appel est-il déjà terminé ? ─────────────────────────────────
        //
        // `EndedCallRegistry` existe exactement pour ça — son en-tête le dit :
        // « pour que l'isolate FCM ignore un push `call` arrivé après
        // `call_ended` ». Mais sur Android le handler Dart sort avant de le
        // consulter, et ce chemin-ci ne le lisait pas du tout : le registre
        // était écrit par tout le monde et lu par personne au moment où l'on
        // fait sonner. Un push d'appel livré après son ordre de fin faisait
        // donc sonner en plein écran, quarante secondes, un appel annulé.
        if (callId.isNotEmpty() && estDejaTermine(context, callId)) {
            Log.i(TAG, "appel déjà terminé, on ne sonne pas: $callId")
            return
        }

        // ── L'utilisateur est-il déjà en communication ? ────────────────────
        //
        // Aucune garde n'existait ici, et le serveur n'en a pas non plus pour
        // les appels de groupe : `create_group_call` sonne chez tout le monde
        // sans consulter l'état d'occupation. Or `isApplicationForeground` rend
        // faux dès que le verrou d'écran est posé — l'état normal d'un appel
        // audio, écran éteint. Une invitation arrivait donc en plein écran,
        // sonnerie comprise, par-dessus une conversation en cours.
        //
        // On l'affiche quand même, mais en sourdine et sans plein écran :
        // l'information a sa place dans le tiroir, l'intrusion non.
        val enCommunication = estEnCommunication(context)
        if (enCommunication) {
            Log.i(TAG, "communication en cours → entrant en sourdine: $callId")
        }

        if (callId.isNotEmpty()) lastShownCallId = callId

        ensureInitialized(context)

        // Sonnerie importée par l'utilisateur : le plugin CallKit ne sait pas
        // jouer un fichier arbitraire, on la joue nous-mêmes et on rend CallKit
        // muet (voir [CustomRingtonePlayer]).
        val listChoice = resolveListCallRingtone(context, data["callerId"].orEmpty())
        val customPath = listChoice?.first ?: resolveCustomRingtonePath(context)
        // Fichier importé → CallKit muet + on joue le fichier. Sinon CallKit
        // joue lui-même la ressource compilée résolue par Flutter.
        val ringtonePath = if (customPath != null) {
            "silence"
        } else {
            listChoice?.second ?: resolveNativeRingtoneName(context)
        }
        val bundle = buildIncomingBundle(
            data,
            if (enCommunication) "silence" else ringtonePath,
            pleinEcran = !enCommunication,
        )
        try {
            notificationManager?.showIncomingNotification(bundle)
            addCall(context.applicationContext, Data.fromBundle(bundle))
            // ── La notification a-t-elle réellement été postée ? ────────────
            //
            // Le plugin ne joue son son et n'affiche quoi que ce soit que si le
            // canal est actif ; son `notify()` est un no-op silencieux quand
            // POST_NOTIFICATIONS est refusée. Notre lecteur, lui, démarrait sans
            // condition — et en boucle. L'utilisateur ayant refusé les
            // notifications et choisi une sonnerie importée entendait donc son
            // téléphone sonner à plein volume, écran vide, sans notification,
            // sans écran d'appel et sans bouton pour décrocher : rien de ce qui
            // arrête la sonnerie à quarante secondes ne passe par un chemin
            // qu'une notification absente peut emprunter.
            if (customPath != null && !enCommunication && notificationsActives(context)) {
                CustomRingtonePlayer.start(context, customPath)
            } else if (customPath != null) {
                Log.i(TAG, "sonnerie importée non démarrée (notification absente ou sourdine)")
            }
            Log.d(TAG, "showIncoming callId=$callId caller=${data["callerId"]} custom=${customPath != null}")
        } catch (e: Exception) {
            Log.e(TAG, "showIncoming failed", e)
        }
    }

    /** L'appel figure-t-il dans le registre des appels terminés écrit par Dart ? */
    private fun estDejaTermine(context: Context, callId: String): Boolean = try {
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE,
        )
        val brut = prefs.getString("flutter.ended_call_ids_v1", null)
        if (brut.isNullOrBlank()) {
            false
        } else {
            val expirations = JSONObject(brut)
            val expire = expirations.optLong(callId, 0L)
            expire > System.currentTimeMillis()
        }
    } catch (e: Exception) {
        Log.w(TAG, "lecture du registre des appels terminés: $e")
        false
    }

    /** Une entrée CallKit acceptée signifie une communication en cours. */
    private fun estEnCommunication(context: Context): Boolean = try {
        getDataActiveCalls(context.applicationContext).any { it.isAccepted }
    } catch (e: Exception) {
        Log.w(TAG, "lecture ACTIVE_CALLS: $e")
        false
    }

    /** Une notification postée maintenant serait-elle visible ? */
    private fun notificationsActives(context: Context): Boolean = try {
        NotificationManagerCompat.from(context.applicationContext)
            .areNotificationsEnabled()
    } catch (e: Exception) {
        Log.w(TAG, "areNotificationsEnabled: $e")
        true
    }

    /** Résout la sonnerie d'appel de la première liste prioritaire du contact. */
    private fun resolveListCallRingtone(
        context: Context,
        callerId: String,
    ): Pair<String?, String>? {
        if (callerId.isBlank()) return null
        return try {
            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE,
            )
            val settings = JSONObject(
                prefs.getString("flutter.list_ringtone_settings_v1", "{}") ?: "{}",
            )
            val members = JSONObject(
                prefs.getString("flutter.list_ringtone_members_v1", "{}") ?: "{}",
            )
            val priority = FlutterSharedPreferencesCompat
                .readStringList(prefs, "list_ringtone_priority_v1")
            val ordered = priority + settings.keys().asSequence().toList()
                .filterNot { priority.contains(it) }
            for (listId in ordered) {
                val listMembers = members.optJSONArray(listId) ?: continue
                val belongs = (0 until listMembers.length())
                    .any { listMembers.optString(it) == callerId }
                if (!belongs) continue
                val optionId = settings.optJSONObject(listId)
                    ?.optString("callRingtoneId")
                    ?.takeIf { it.isNotBlank() && it != "null" }
                    ?: continue
                if (optionId.startsWith("bundled_son")) {
                    val number = optionId.removePrefix("bundled_son")
                    return Pair(null, "rt_son$number")
                }
                if (optionId == "__system_default__") {
                    return Pair(null, "system_ringtone_default")
                }
                val entries = FlutterSharedPreferencesCompat
                    .readStringList(prefs, "call_ringtone_custom_list")
                for (raw in entries) {
                    val item = JSONObject(raw)
                    if (item.optString("id") == optionId) {
                        val path = item.optString("filePath")
                        if (path.isNotBlank() && java.io.File(path).exists()) {
                            return Pair(path, "silence")
                        }
                    }
                }
            }
            null
        } catch (e: Exception) {
            Log.e(TAG, "resolveListCallRingtone failed", e)
            null
        }
    }

    /**
     * Chemin du fichier de sonnerie importé actuellement sélectionné, ou null
     * si l'utilisateur est sur la sonnerie système / fournie par l'app (dans
     * ces cas CallKit joue son propre son). Écrit par Flutter
     * (`RingtonePreferences`) dans les SharedPreferences du plugin
     * shared_preferences.
     */
    private fun resolveCustomRingtonePath(context: Context): String? {
        return try {
            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE,
            )
            val path = prefs.getString("flutter.call_ringtone_active_path", null)
                ?.trim()
                .orEmpty()
            if (path.isNotEmpty() && java.io.File(path).exists()) path else null
        } catch (e: Exception) {
            Log.e(TAG, "resolveCustomRingtonePath failed", e)
            null
        }
    }

    /**
     * Nom de ressource `res/raw` que CallKit doit jouer pour la sonnerie
     * fournie/système sélectionnée (écrit par Flutter `RingtonePreferences`).
     * Défaut : sonnerie système.
     */
    private fun resolveNativeRingtoneName(context: Context): String {
        return try {
            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE,
            )
            prefs.getString("flutter.call_ringtone_native_name", null)
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: "system_ringtone_default"
        } catch (e: Exception) {
            Log.e(TAG, "resolveNativeRingtoneName failed", e)
            "system_ringtone_default"
        }
    }

    fun dismissIncomingSilently(context: Context, callId: String) {
        val id = callId.trim()
        if (id.isEmpty()) return
        CallDismissRegistry.markProgrammaticDismiss(id)
        endCall(context, mapOf("callId" to id))
    }

    /**
     * Coupe la sonnerie native jouée par CETTE instance (soundManager propre).
     * Nécessaire car le BroadcastReceiver du plugin arrête le soundManager du
     * plugin (ou rien si l'app est tuée : FlutterCallkitIncomingPlugin.getInstance()
     * est null), jamais celui-ci → sinon la sonnerie continue après refus/accept.
     */
    fun stopSound() {
        try {
            soundManager?.stop()
        } catch (e: Exception) {
            Log.e(TAG, "stopSound failed", e)
        }
    }

    /**
     * Annule explicitement la notification d'appel EN COURS d'un [callId] (id
     * calqué sur le plugin : `("ongoing_$callId").hashCode()`). Complète
     * stopService : sur certains OEM la notif de service au premier plan ne
     * disparaît pas toujours à l'arrêt du service.
     */
    fun cancelOngoingNotification(context: Context, callId: String) {
        val id = callId.trim()
        if (id.isEmpty()) return
        try {
            NotificationManagerCompat.from(context.applicationContext)
                .cancel("ongoing_$id".hashCode())
        } catch (e: Exception) {
            Log.e(TAG, "cancelOngoingNotification failed", e)
        }
    }

    fun endCall(context: Context, data: Map<String, String>) {
        ensureInitialized(context)
        lastShownCallId = null
        // Couper la sonnerie importée jouée nativement (voir CustomRingtonePlayer).
        CustomRingtonePlayer.stop()
        // Coupe aussi le service/notification d'appel EN COURS (chronomètre +
        // raccrocher). Le plugin ne le fait pas quand getInstance() est null
        // (app tuée) → sinon notification fantôme aux boutons morts après l'appel.
        try {
            CallkitNotificationService.stopService(context.applicationContext)
        } catch (e: Exception) {
            Log.e(TAG, "stopService (endCall) failed", e)
        }
        val callId = (data["callId"] ?: "").trim()
        // Retrait piloté par le serveur (push call_ended) ou par Flutter — pas
        // un refus utilisateur : marquer AVANT removeCall pour que le listener
        // ACTIVE_CALLS de TalkyApplication ne POST pas /calls/reject.
        try {
            if (callId.isNotEmpty()) {
                CallDismissRegistry.markProgrammaticDismiss(callId)
            } else {
                getDataActiveCalls(context.applicationContext).forEach {
                    CallDismissRegistry.markProgrammaticDismiss(it.id)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "markProgrammaticDismiss (endCall) failed", e)
        }
        try {
            if (callId.isEmpty()) {
                soundManager?.stop()
                removeAllCalls(context.applicationContext)
                Log.d(TAG, "endCall all")
                return
            }
            cancelOngoingNotification(context, callId)
            val bundle = Data(hashMapOf<String, Any?>("id" to callId)).toBundle()
            notificationManager?.clearIncomingNotification(bundle, false)
            removeCall(context.applicationContext, Data.fromBundle(bundle))
            Log.d(TAG, "endCall callId=$callId")
        } catch (e: Exception) {
            Log.e(TAG, "endCall failed", e)
        }
    }

    private fun buildIncomingBundle(
        data: Map<String, String>,
        ringtonePath: String = "system_ringtone_default",
        pleinEcran: Boolean = true,
    ): android.os.Bundle {
        val callId = (data["callId"] ?: data["roomId"] ?: "").trim()
        val callerId = data["callerId"] ?: ""
        val callerName = data["callerName"] ?: data["title"] ?: "Alanya"
        val isVideo = data["isVideo"] == "true"
        val sessionId = (data["sessionId"] ?: "").trim()
        val roomId = (data["roomId"] ?: sessionId).ifBlank {
            if (callId.startsWith("conf_")) callId else ""
        }
        val photo = data["photo"] ?: ""

        val extra = hashMapOf<String, Any?>(
            "callId" to callId,
            "callerId" to callerId,
            "callerName" to callerName,
            "callerPhoto" to photo,
            "isVideo" to isVideo,
            "roomId" to roomId,
            "sessionId" to (sessionId.ifBlank { if (callId.startsWith("conf_")) callId else "" }),
            "sessionKind" to (data["sessionKind"] ?: if (callId.startsWith("conf_")) "conference" else ""),
            "mode" to (data["mode"] ?: ""),
            // Fraîcheur pour le cold start Flutter (main.dart) : une entrée
            // ACTIVE_CALLS résiduelle d'un essai précédent ne doit jamais
            // déclencher une auto-réponse ou un écran entrant fantôme.
            "shownAt" to System.currentTimeMillis(),
        )

        val args = hashMapOf<String, Any?>(
            "id" to callId,
            "nameCaller" to callerName,
            "appName" to "Alanya",
            "handle" to callerId,
            "avatar" to photo,
            "type" to if (isVideo) 1 else 0,
            // Sous le NO_ANSWER_MS serveur (45 s) : la notification doit expirer
            // AVANT que le serveur classe l'appel « sans réponse », jamais après.
            "duration" to 40000L,
            "extra" to extra,
            "android" to hashMapOf(
                "isCustomNotification" to true,
                "isShowLogo" to false,
                // Depuis la 3.x, `Data` lit ces libellés dans `android` et non
                // plus à la racine : les y laisser rendait les boutons de la
                // notification aux valeurs par défaut du plugin, en anglais.
                "textAccept" to "Accepter",
                "textDecline" to "Refuser",
                // Résolu par l'appelant : nom de ressource res/raw compilée
                // ('ringback', 'system_ringtone_default'), ou 'silence' quand on
                // joue nous-mêmes un fichier importé (voir CustomRingtonePlayer).
                // NB : passer "" ne rend PAS muet — le plugin retombe alors sur
                // la sonnerie système.
                "ringtonePath" to ringtonePath,
                "backgroundColor" to "#0955fa",
                "actionColor" to "#4CAF50",
                "incomingCallNotificationChannelName" to "Appels entrants",
                "missedCallNotificationChannelName" to "Appels manqués",
                "isShowFullLockedScreen" to pleinEcran,
            ),
        )
        val bundle = Data(args).toBundle()
        // CRUCIAL — quand l'app est tuée, le tap « Accepter » déclenche
        // ContextCompat.startForegroundService(CallkitNotificationService) alors
        // que le service ne peut PAS appeler startForeground() : son
        // CallkitNotificationManager vient de FlutterCallkitIncomingPlugin
        // .getInstance(), null tant qu'aucun engine Flutter n'est attaché →
        // ForegroundServiceDidNotStartInTimeException ~10 s après l'acceptation,
        // le process meurt en plein appel. Avec ce flag à false, l'accept passe
        // par startService + stopSelf (aucun contrat startForeground) ; le
        // foreground service légitime est démarré ensuite par Dart
        // (CallKitService.startOutgoingCall) une fois l'engine prêt.
        bundle.putBoolean(CallkitConstants.EXTRA_CALLKIT_CALLING_SHOW, false)
        return bundle
    }

    /**
     * Efface la notification d'appel ENTRANT d'un [callId] (sonnerie comprise).
     * Utilisé par TalkyApplication quand l'appel passe à isAccepted : la branche
     * ACCEPT du service plugin ne peut pas le faire (manager null app tuée), et
     * avec EXTRA_CALLKIT_CALLING_SHOW=false elle fait stopSelf() immédiatement.
     */
    fun clearIncomingNotification(context: Context, callId: String) {
        val id = callId.trim()
        if (id.isEmpty()) return
        ensureInitialized(context)
        try {
            val bundle = Data(hashMapOf<String, Any?>("id" to id)).toBundle()
            notificationManager?.clearIncomingNotification(bundle, true)
        } catch (e: Exception) {
            Log.e(TAG, "clearIncomingNotification failed", e)
        }
    }
}
