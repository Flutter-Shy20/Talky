import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/media_expiry.dart';

/// Durée de rétention des médias, apprise du serveur.
///
/// Ce n'est pas une préférence utilisateur : c'est un fait sur le serveur, que
/// le client mémorise pour pouvoir répondre seul à « ce média est-il encore
/// là ? ». D'où un stockage séparé de [MediaDownloadPreferences].
///
/// ── Pourquoi l'apprendre plutôt que la coder en dur ──
///
/// La rétention est réglable côté serveur — variable d'environnement, et
/// surcharge depuis l'espace super-admin. Elle vaut 365 jours pendant la mise
/// en service du stockage partitionné, 30 ensuite. Une constante figée ici
/// finirait par diverger, et le client masquerait des médias vivants — ou
/// afficherait des vignettes qui ne chargeront jamais.
///
/// Chaque réponse `410 Gone` porte le champ `retentionDays` : c'est la source.
/// Tant que rien n'a été appris, le client ne présume rien et laisse les
/// requêtes partir.
///
/// ── Ce que ça évite ──
///
/// Sans cette mémoire, chaque affichage d'un vieux message relancerait un
/// téléchargement voué au 410 : attente réseau, puis image cassée
/// indiscernable d'une panne de connexion. Avec elle, l'app sait avant de
/// partir, et affiche « Média expiré » tout de suite.
class MediaExpiryPolicy {
  MediaExpiryPolicy._();

  static const _kRetentionDaysKey = 'media_retention_days_learned';

  static int? _retentionDays;
  static bool _charge = false;

  /// Rétention connue, ou `null` si le serveur ne l'a pas encore annoncée.
  static int? get retentionDays => _retentionDays;

  /// À appeler dans `main()`, comme [MediaDownloadPreferences.preload].
  static Future<void> preload() async {
    if (_charge) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getInt(_kRetentionDaysKey);
      if (v != null && v > 0) _retentionDays = v;
    } catch (e) {
      debugPrint('[MediaExpiry] préchargement impossible: $e');
    }
    _charge = true;
  }

  /// Mémorise la rétention annoncée par une réponse `410`.
  ///
  /// Best-effort : une écriture ratée n'est pas une erreur fonctionnelle,
  /// l'information sera réapprise à la prochaine réponse du serveur.
  static Future<void> remember(int jours) async {
    if (jours <= 0 || jours == _retentionDays) return;
    _retentionDays = jours;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kRetentionDaysKey, jours);
    } catch (e) {
      debugPrint('[MediaExpiry] mémorisation impossible: $e');
    }
  }

  /// Lit une réponse serveur et en tire la rétention si c'est un `410`.
  ///
  /// Renvoie `true` si la réponse dit « ce média a expiré » — l'appelant peut
  /// alors cesser de réessayer, au lieu de traiter l'échec comme un incident
  /// réseau passager.
  static bool noteResponse(int statusCode, {String? body}) {
    if (statusCode != kMediaGoneStatus) return false;
    if (body != null && body.isNotEmpty) {
      try {
        final json = jsonDecode(body);
        if (json is Map && json['error'] == kMediaExpiredError) {
          final jours = json['retentionDays'];
          if (jours is int) remember(jours);
        }
      } catch (_) {
        // Corps illisible : le 410 seul suffit à conclure que le média est mort.
      }
    }
    return true;
  }

  /// `true` si ce média est certainement mort, sans aucune requête réseau.
  ///
  /// Prudent : `false` dès qu'un doute existe — URL non partitionnée, rétention
  /// pas encore apprise. Un faux négatif coûte une requête ; un faux positif
  /// masquerait un média que l'utilisateur pourrait encore voir.
  static bool isExpired(String? url, {DateTime? now}) =>
      isMediaExpired(url, retentionDays: _retentionDays, now: now);

  /// Réinitialise l'état mémoire. Réservé aux tests.
  @visibleForTesting
  static void resetForTests({int? retentionDays}) {
    _retentionDays = retentionDays;
    _charge = true;
  }
}
