package com.alanya237.alanya

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.KeyStore

/**
 * Santé du magasin chiffré de flutter_secure_storage : sonde au démarrage et
 * remise à zéro quand il est devenu illisible.
 *
 * Le plugin chiffre ses valeurs avec `EncryptedSharedPreferences`, dont la clé
 * maîtresse vit dans le Keystore Android. Cette clé ne quitte jamais
 * l'appareil : restauration d'une sauvegarde, transfert d'appareil à appareil
 * ou réinitialisation du Keystore laissent un fichier de préférences chiffré
 * face à une clé absente ou incompatible.
 *
 * Le plugin bascule alors silencieusement sur son chiffrement hérité
 * (AES/CBC via javax.crypto) et chaque lecture lève
 * `BadPaddingException: BAD_DECRYPT`, ce qui bloque l'écran de connexion.
 *
 * Deux détails imposent de traiter le problème AVANT le démarrage de Flutter :
 *
 * 1. Le drapeau interne `failedToUseEncryptedSharedPreferences` du plugin est
 *    collant pour toute la durée du process. Une fois levé, plus aucune lecture
 *    ne repasse par le magasin chiffré, même après réparation.
 * 2. Son `resetOnError` vide bien le fichier, mais **pas** l'alias Keystore
 *    fautif : à chaque démarrage `EncryptedSharedPreferences` échoue à nouveau
 *    et l'app reste en mode dégradé.
 *
 * D'où [verifyAndRepair], appelé depuis [TalkyApplication.onCreate] : on tente
 * l'ouverture exactement comme le plugin le fera, et si elle échoue on efface
 * le fichier ET l'alias pour que l'initialisation du plugin reparte sur une
 * clé neuve. L'utilisateur perd sa session — elle était de toute façon
 * illisible — et retrouve un écran de connexion fonctionnel.
 */
object SecureStorageRepair {

    private const val TAG = "TalkySecureRepair"

    /** Nom par défaut du fichier de flutter_secure_storage. */
    private const val PREFS_NAME = "FlutterSecureStorage"

    /** Alias par défaut de androidx.security.crypto.MasterKey. */
    private const val MASTER_KEY_ALIAS = "_androidx_security_master_key_"

    private const val ANDROID_KEYSTORE = "AndroidKeyStore"

    /** Préférences en clair : ne sert qu'à mémoriser une réparation demandée. */
    private const val STATE_PREFS = "talky_secure_storage_state"
    private const val KEY_REPAIR_PENDING = "repair_pending"

    @Volatile
    private var alreadyVerified = false

    /**
     * Sonde le magasin et le remet à zéro s'il est illisible. Renvoie true si
     * une réparation a eu lieu.
     *
     * À appeler dans `Application.onCreate`, donc avant que le moteur Flutter
     * — et le plugin — ne touche au magasin. Idempotent : la sonde ne tourne
     * qu'une fois par process.
     */
    fun verifyAndRepair(context: Context): Boolean {
        if (alreadyVerified) return false
        alreadyVerified = true

        val appCtx = context.applicationContext
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false

        return try {
            // Une session précédente a réparé à chaud : le plugin a pu réécrire
            // entre-temps avec un chiffrement hérité dont la clé enveloppée a
            // été effacée. On repart d'un fichier vide.
            if (consumeRepairPending(appCtx)) {
                Log.w(TAG, "réparation différée demandée par la session précédente")
                return reset(appCtx)
            }
            if (probe(appCtx)) {
                false
            } else {
                Log.w(TAG, "magasin chiffré illisible : remise à zéro")
                reset(appCtx)
            }
        } catch (t: Throwable) {
            // Rien ici ne doit faire tomber le démarrage de l'app.
            Log.e(TAG, "vérification du magasin échouée", t)
            false
        }
    }

    /**
     * Ouvre le magasin comme le fera le plugin et déchiffre toutes ses entrées.
     * Renvoie false dès qu'une étape échoue : keyset Tink indéchiffrable (cas
     * de la sauvegarde restaurée) comme valeur individuelle corrompue.
     */
    private fun probe(context: Context): Boolean = try {
        val entries = openEncrypted(context).all
        Log.d(TAG, "magasin chiffré lisible (${entries.size} entrées)")
        true
    } catch (e: Exception) {
        Log.w(TAG, "ouverture du magasin chiffré échouée: ${e.javaClass.simpleName}: ${e.message}")
        false
    }

    /**
     * Réplique exacte de `FlutterSecureStorage.initializeEncryptedSharedPreferencesManager`
     * (flutter_secure_storage 9.2.4). Toute divergence de spec produirait une
     * clé maîtresse différente et rendrait la sonde inutile.
     */
    private fun openEncrypted(context: Context): android.content.SharedPreferences {
        val spec = KeyGenParameterSpec.Builder(
            MasterKey.DEFAULT_MASTER_KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setKeySize(256)
            .build()
        val masterKey = MasterKey.Builder(context).setKeyGenParameterSpec(spec).build()
        return EncryptedSharedPreferences.create(
            context,
            PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    /**
     * Vide le magasin et supprime la clé maîtresse. Renvoie true si au moins
     * une des deux opérations a abouti.
     *
     * Ne détruit que des données déjà indéchiffrables : la session est perdue
     * dans tous les cas, l'utilisateur se reconnecte.
     */
    fun reset(context: Context): Boolean {
        var repaired = false
        val appCtx = context.applicationContext

        try {
            appCtx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .clear()
                .commit()
            repaired = true
            Log.i(TAG, "préférences chiffrées vidées")
        } catch (e: Exception) {
            Log.e(TAG, "vidage des préférences échoué", e)
        }

        try {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            if (keyStore.containsAlias(MASTER_KEY_ALIAS)) {
                keyStore.deleteEntry(MASTER_KEY_ALIAS)
                repaired = true
                Log.i(TAG, "clé maîtresse Keystore supprimée")
            }
        } catch (e: Exception) {
            Log.e(TAG, "suppression de la clé maîtresse échouée", e)
        }

        clearRepairPending(appCtx)
        return repaired
    }

    /**
     * Réparation à chaud, déclenchée par Dart quand une lecture a malgré tout
     * levé une erreur de déchiffrement.
     *
     * Elle ne peut pas rétablir le magasin chiffré pour la session en cours :
     * le drapeau collant du plugin l'a définitivement basculé sur son
     * chiffrement hérité. On note donc une purge à effectuer au prochain
     * démarrage, sans quoi les valeurs réécrites d'ici là — chiffrées avec une
     * clé AES dont la copie enveloppée vient d'être effacée — seraient à leur
     * tour illisibles.
     */
    fun repairNow(context: Context): Boolean {
        val appCtx = context.applicationContext
        val repaired = reset(appCtx)
        markRepairPending(appCtx)
        return repaired
    }

    private fun statePrefs(context: Context) =
        context.getSharedPreferences(STATE_PREFS, Context.MODE_PRIVATE)

    private fun markRepairPending(context: Context) {
        try {
            statePrefs(context).edit().putBoolean(KEY_REPAIR_PENDING, true).commit()
        } catch (e: Exception) {
            Log.e(TAG, "marquage de la réparation différée échoué", e)
        }
    }

    private fun consumeRepairPending(context: Context): Boolean = try {
        val prefs = statePrefs(context)
        val pending = prefs.getBoolean(KEY_REPAIR_PENDING, false)
        if (pending) prefs.edit().remove(KEY_REPAIR_PENDING).commit()
        pending
    } catch (e: Exception) {
        Log.e(TAG, "lecture de la réparation différée échouée", e)
        false
    }

    private fun clearRepairPending(context: Context) {
        try {
            statePrefs(context).edit().remove(KEY_REPAIR_PENDING).commit()
        } catch (e: Exception) {
            Log.e(TAG, "nettoyage de la réparation différée échoué", e)
        }
    }
}
