package com.alanya237.alanya

import android.content.pm.ServiceInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallMediaFgsTypesTest {

    private val phoneCall = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
    private val micro = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
    private val camera = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA

    private fun candidats(
        isVideo: Boolean = false,
        micAccorde: Boolean = true,
        cameraAccordee: Boolean = true,
    ) = CallMediaFgsTypes.typesCandidats(
        isVideo = isVideo,
        micAccorde = micAccorde,
        cameraAccordee = cameraAccordee,
    )

    @Test
    fun `appel audio - le micro est demande avant le repli`() {
        assertEquals(listOf(phoneCall or micro, phoneCall), candidats())
    }

    @Test
    fun `appel video - micro et camera d'abord, puis micro seul`() {
        assertEquals(
            listOf(phoneCall or micro or camera, phoneCall or micro, phoneCall),
            candidats(isVideo = true),
        )
    }

    @Test
    fun `video sans permission camera - la camera n'est pas demandee`() {
        // Un appel vidéo tourne légitimement sans permission caméra, en audio.
        // Demander le type `camera` ferait lever startForeground et emporterait
        // le micro du même masque.
        assertEquals(
            listOf(phoneCall or micro, phoneCall),
            candidats(isVideo = true, cameraAccordee = false),
        )
    }

    @Test
    fun `sans permission micro - phoneCall seul`() {
        assertEquals(listOf(phoneCall), candidats(micAccorde = false))
        assertEquals(
            listOf(phoneCall),
            candidats(isVideo = true, micAccorde = false, cameraAccordee = true),
        )
    }

    @Test
    fun `phoneCall termine toujours l'escalier`() {
        // C'est le seul type qu'Android accorde encore depuis l'arrière-plan :
        // sans lui en dernier, un appel décroché depuis une notification
        // n'aurait aucun service au premier plan, et ne survivrait pas à la
        // mise en veille.
        for (video in listOf(false, true)) {
            for (mic in listOf(false, true)) {
                for (cam in listOf(false, true)) {
                    val liste = candidats(video, mic, cam)
                    assertEquals(phoneCall, liste.last())
                    assertTrue(liste.isNotEmpty())
                }
            }
        }
    }

    @Test
    fun `le type obtenu se relit`() {
        assertTrue(CallMediaFgsTypes.porteLeMicro(phoneCall or micro))
        assertFalse(CallMediaFgsTypes.porteLeMicro(phoneCall))
        assertTrue(CallMediaFgsTypes.porteLaCamera(phoneCall or micro or camera))
        assertFalse(CallMediaFgsTypes.porteLaCamera(phoneCall or micro))
    }

    @Test
    fun `la description nomme ce qui est porte`() {
        assertEquals("phoneCall+micro", CallMediaFgsTypes.decrire(phoneCall or micro))
        assertEquals("phoneCall", CallMediaFgsTypes.decrire(phoneCall))
        assertEquals(
            "phoneCall+micro+caméra",
            CallMediaFgsTypes.decrire(phoneCall or micro or camera),
        )
    }
}
