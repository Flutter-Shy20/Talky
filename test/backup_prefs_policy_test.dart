import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/backup/backup_prefs_policy.dart';

/// Garde-fou de la liste blanche des préférences sauvegardées.
///
/// ── Pourquoi ce test lit le code source, chose inhabituelle ──
///
/// Un test qui interrogerait `SharedPreferences` à l'exécution ne verrait que
/// les clés déjà écrites sur l'appareil de test — donc jamais celle qu'un
/// collègue vient d'ajouter. Seule l'inspection des sources voit une clé
/// **déclarée**.
///
/// Sans lui, la liste blanche se périme en silence : six mois plus tard,
/// quelqu'un ajoute une préférence, ne connaît pas ce fichier, et elle n'est
/// simplement jamais restaurée — sans que rien ne le signale.
void main() {
  /// Deux formes de déclaration couvrent l'essentiel du code existant :
  /// l'appel direct `prefs.getString('ma_cle')` et la constante
  /// `static const _kMaCleKey = 'ma_cle'`.
  final patterns = [
    RegExp(
      r"""prefs\.(?:get|set)(?:String|Bool|Int|Double|StringList)\(\s*'([^']+)'""",
    ),
    RegExp(r"""_k[A-Za-z0-9_]*Key\s*=\s*'([^']+)'"""),
  ];

  /// Forme d'une clé de préférence dans ce projet : minuscules, chiffres et
  /// tirets bas. Ce filtre écarte les faux positifs — la constante
  /// `_kVapidPublicKey` de `push_service.dart` correspond au second motif sans
  /// être une clé `SharedPreferences`. Il tient tant que la convention de
  /// nommage tient, et il la fait donc respecter au passage.
  final looksLikePrefKey = RegExp(r'^[a-z][a-z0-9_]{2,48}$');

  Set<String> declaredKeys() {
    final found = <String>{};
    final lib = Directory('lib');
    if (!lib.existsSync()) return found;
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Le fichier de politique lui-même cite les clés : les recompter
      // ferait boucler le raisonnement.
      if (entity.path.endsWith('backup_prefs_policy.dart')) continue;
      final source = entity.readAsStringSync();
      for (final pattern in patterns) {
        for (final m in pattern.allMatches(source)) {
          final key = m.group(1);
          if (key != null && looksLikePrefKey.hasMatch(key)) found.add(key);
        }
      }
    }
    return found;
  }

  test('toute clé de préférence déclarée est classée', () {
    final unclassified = declaredKeys().difference(kClassifiedPrefKeys);

    expect(
      unclassified,
      isEmpty,
      reason: 'Ces clés SharedPreferences ne sont dans aucun des trois '
          'ensembles de backup_prefs_policy.dart :\n'
          '  ${unclassified.join('\n  ')}\n\n'
          'Décidez pour chacune :\n'
          '  kBackedUpKeys     — un choix de l\'inscrit, à retrouver sur son '
          'nouveau téléphone\n'
          '  kDeviceLocalKeys  — propre à cet appareil (chemin, jeton, '
          'drapeau d\'écran vu)\n'
          '  kServerOwnedKeys  — déjà synchronisée par compte côté serveur\n\n'
          'Dans le doute, kDeviceLocalKeys : ne pas restaurer une préférence '
          'se corrige en trois secondes, recopier un secret ne se corrige pas.',
    );
  });

  test('les trois ensembles ne se recouvrent pas', () {
    // Une clé dans deux ensembles rendrait la règle ambiguë, et la règle
    // ambiguë finit toujours par être tranchée du mauvais côté.
    expect(kBackedUpKeys.intersection(kDeviceLocalKeys), isEmpty);
    expect(kBackedUpKeys.intersection(kServerOwnedKeys), isEmpty);
    expect(kDeviceLocalKeys.intersection(kServerOwnedKeys), isEmpty);
  });

  test('aucun jeton ni secret ne figure dans la liste de sauvegarde', () {
    // Filet de sécurité en plus du classement manuel : un nom qui sent le
    // secret ne doit jamais voyager, même si quelqu'un l'a classé par erreur.
    const suspicious = ['token', 'secret', 'password', 'jwt', 'refresh', 'key'];
    for (final key in kBackedUpKeys) {
      for (final word in suspicious) {
        expect(
          key.toLowerCase().contains(word),
          isFalse,
          reason: '« $key » ressemble à un secret et ne devrait pas être '
              'sauvegardée',
        );
      }
    }
  });

  test('collectBackedUpPrefs ne prend que les clés autorisées', () {
    final source = {
      'app_locale': 'fr',
      'theme_mode': 'dark',
      // Non classée en sauvegarde : ne doit pas sortir.
      'call_ringtone_active_path': '/data/sonnerie.mp3',
      'inconnue_du_futur': 'valeur',
    };
    final collected = collectBackedUpPrefs((k) => source[k]);

    expect(collected.keys, containsAll(['app_locale', 'theme_mode']));
    expect(collected.containsKey('call_ringtone_active_path'), isFalse);
    expect(collected.containsKey('inconnue_du_futur'), isFalse);
  });

  test('filterRestorablePrefs refuse ce qu\'une archive tenterait d\'injecter',
      () {
    // La liste blanche s'applique aussi à la LECTURE : une archive fabriquée
    // à la main ne doit pas pouvoir écrire n'importe quoi dans les préférences.
    final restored = filterRestorablePrefs({
      'app_locale': 'en',
      'auth_access_token': 'volé',
      'call_ringtone_active_path': '/chemin/inexistant',
      'media_wifi_only': true,
      'hidden_calls_v1': ['1', '2'],
    });

    expect(restored['app_locale'], 'en');
    expect(restored['media_wifi_only'], true);
    expect(restored['hidden_calls_v1'], ['1', '2']);
    expect(restored.containsKey('auth_access_token'), isFalse);
    expect(restored.containsKey('call_ringtone_active_path'), isFalse);
  });
}
