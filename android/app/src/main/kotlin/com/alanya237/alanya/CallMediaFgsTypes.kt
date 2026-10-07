package com.alanya237.alanya

import android.content.pm.ServiceInfo
import android.os.Build
import androidx.annotation.RequiresApi

/**
 * Les types de service au premier plan à demander pendant un appel, du plus
 * complet au plus sûr.
 *
 * Deux contraintes qui se contredisent, et qu'un seul type ne peut pas tenir :
 *
 * `microphone` est ce qui donne l'accès au micro quand l'application n'est plus
 * à l'écran. À partir d'Android 11, le système n'accorde la capacité de capture
 * qu'aux services dont le type la nomme — `microphone` pour le micro, `camera`
 * pour la caméra. Rien d'autre ne la donne : ni `phoneCall`, ni la connexion
 * Telecom, ni la permission `RECORD_AUDIO`, qui reste accordée pendant que le
 * système ne livre plus que du silence.
 *
 * `phoneCall` est ce qui démarre toujours. Depuis Android 14, `startForeground`
 * lève sur un type soumis aux restrictions « while-in-use » quand
 * l'application est en arrière-plan — c'est-à-dire au décrochage depuis une
 * notification, le cas qui compte le plus. Demander `microphone` seul faisait
 * donc échouer le service entier, et un appel sans service au premier plan ne
 * survit pas à la mise en veille.
 *
 * D'où l'escalier : on demande le type complet, et on retombe jusqu'à
 * `phoneCall`, qui ne peut pas échouer. Un appel décroché depuis l'arrière-plan
 * démarre ainsi sans micro plutôt que sans service, et `CallSessionGuard`
 * relance le service au retour à l'écran pour regagner ce qui manquait.
 *
 * Une permission manquante se vérifie avant d'être demandée, car un type dont
 * la permission n'est pas accordée fait lever `startForeground` et emporte avec
 * lui tous ceux du même masque. C'est le piège déjà tendu une fois par un appel
 * vidéo sans permission caméra : il tourne légitimement, en audio.
 */
object CallMediaFgsTypes {

    /**
     * Les masques à tenter, dans l'ordre. Le dernier est toujours `phoneCall`
     * seul : il n'exige que `MANAGE_OWN_CALLS`, déclarée au manifeste, et reste
     * accordé depuis l'arrière-plan.
     */
    @RequiresApi(Build.VERSION_CODES.Q)
    fun typesCandidats(
        isVideo: Boolean,
        micAccorde: Boolean,
        cameraAccordee: Boolean,
    ): List<Int> {
        val phoneCall = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
        val micro = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        val camera = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA

        val candidats = mutableListOf<Int>()
        if (micAccorde && isVideo && cameraAccordee) {
            candidats += phoneCall or micro or camera
        }
        if (micAccorde) {
            candidats += phoneCall or micro
        }
        candidats += phoneCall
        return candidats
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    fun porteLeMicro(type: Int): Boolean =
        (type and ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE) != 0

    @RequiresApi(Build.VERSION_CODES.Q)
    fun porteLaCamera(type: Int): Boolean =
        (type and ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA) != 0

    /** Pour les journaux : « phoneCall+micro+caméra » plutôt qu'un entier. */
    @RequiresApi(Build.VERSION_CODES.Q)
    fun decrire(type: Int): String {
        val parts = mutableListOf<String>()
        if ((type and ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL) != 0) {
            parts += "phoneCall"
        }
        if (porteLeMicro(type)) parts += "micro"
        if (porteLaCamera(type)) parts += "caméra"
        return if (parts.isEmpty()) "aucun" else parts.joinToString("+")
    }
}
