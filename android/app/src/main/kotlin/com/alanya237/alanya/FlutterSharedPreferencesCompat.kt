package com.alanya237.alanya

import android.content.SharedPreferences
import android.util.Log
import org.json.JSONArray

/**
 * Lecture des clés écrites par le plugin Flutter `shared_preferences`.
 * Les entiers y sont stockés en [Long] — un [SharedPreferences.getString]
 * provoque un ClassCastException.
 */
object FlutterSharedPreferencesCompat {
    private const val TAG = "FlutterPrefsCompat"
    private const val FLUTTER_PREFIX = "flutter."

    /**
     * Sentinelle dont `shared_preferences` préfixe les listes.
     *
     * Une liste n'est pas stockée comme du JSON nu : la forme actuelle est
     * `VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu!` suivi du JSON, la forme
     * héritée la même sentinelle sans `!` suivie de Java sérialisé en base64.
     * `JSONArray()` sur la chaîne complète lève donc systématiquement.
     */
    private const val JSON_LIST_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu!"
    private const val LEGACY_LIST_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"

    fun intKey(dartKey: String): String = FLUTTER_PREFIX + dartKey

    fun readInt(prefs: SharedPreferences, dartKey: String): Int? {
        val key = intKey(dartKey)
        if (!prefs.contains(key)) return null
        return when (val value = prefs.all[key]) {
            is Int -> value
            is Long -> value.toInt()
            is String -> value.toIntOrNull()
            else -> null
        }
    }

    /**
     * Lit une liste de chaînes écrite par Flutter.
     *
     * Le natif décodait la valeur avec `JSONArray(raw)`, sentinelle comprise :
     * l'exception était avalée et on retombait sur une liste vide. Conséquence,
     * **application tuée uniquement** — au premier plan c'est Flutter qui
     * décode, et rien ne se voyait : l'ordre de priorité des listes était
     * ignoré, et une sonnerie attachée à une liste jamais retrouvée. On
     * entendait la sonnerie globale, pour les appels comme pour les messages.
     *
     * La forme héritée porte du Java sérialisé, pas du JSON : elle n'est pas
     * décodable ici et se signale plutôt que de se taire. Une valeur stockée en
     * `Set` — le cas des versions plus anciennes du plugin — est rendue telle
     * quelle.
     */
    fun readStringList(prefs: SharedPreferences, dartKey: String): List<String> =
        when (val value = prefs.all[FLUTTER_PREFIX + dartKey]) {
            is Set<*> -> value.map { it.toString() }
            is String -> decodeStringList(value)
            else -> emptyList()
        }

    /** Décode la valeur brute d'une liste `shared_preferences`. */
    fun decodeStringList(raw: String): List<String> {
        val payload = when {
            raw.startsWith(JSON_LIST_PREFIX) -> raw.removePrefix(JSON_LIST_PREFIX)
            raw.startsWith(LEGACY_LIST_PREFIX) -> {
                Log.w(TAG, "liste au format hérité (Java sérialisé) — non décodable ici")
                return emptyList()
            }
            else -> raw
        }
        return try {
            val array = JSONArray(payload)
            (0 until array.length()).map { array.getString(it) }
        } catch (e: Exception) {
            Log.w(TAG, "decodeStringList: $e")
            emptyList()
        }
    }
}
