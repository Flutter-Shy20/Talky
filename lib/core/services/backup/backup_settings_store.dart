import 'package:shared_preferences/shared_preferences.dart';

import 'backup_schedule.dart';
import 'backup_target.dart';

/// Lit et écrit la fréquence choisie et l'état des sauvegardes de cet appareil.
///
/// Deux natures de données volontairement voisines mais distinctes :
///
/// - **La fréquence** est un choix de l'inscrit. Elle a sa place dans une
///   sauvegarde : il serait agacé de devoir la reposer sur son nouveau
///   téléphone.
/// - **L'état** (dernier succès, dernière tentative, échecs consécutifs)
///   décrit les tentatives faites depuis *ce téléphone-ci*. Le restaurer
///   ailleurs ferait croire à une sauvegarde qui n'a jamais eu lieu sur le
///   nouvel appareil, et retarderait la première vraie.
///
/// C'est exactement la distinction que `backup_prefs_policy.dart` fait
/// respecter, et que son test empêche d'oublier.
class BackupSettingsStore {
  static const String _kFrequencyKey = 'backup_frequency';
  static const String _kDestinationKey = 'backup_destination';
  static const String _kLastSuccessKey = 'backup_last_success_at';
  static const String _kLastAttemptKey = 'backup_last_attempt_at';
  static const String _kFailuresKey = 'backup_consecutive_failures';
  static const String _kFirstFailureKey = 'backup_first_failure_at';
  static const String _kLastFallbackKey = 'backup_last_fallback_at';

  const BackupSettingsStore();

  Future<BackupFrequency> frequency() async {
    final prefs = await SharedPreferences.getInstance();
    return BackupFrequency.parse(prefs.getString(_kFrequencyKey));
  }

  Future<void> setFrequency(BackupFrequency value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFrequencyKey, value.name);
  }

  /// Destination choisie. **`device` par défaut**, et non `drive` : tant que
  /// personne n'a autorisé Google, viser Drive ferait échouer chaque
  /// sauvegarde et afficher un bandeau d'alerte à quelqu'un qui n'a rien
  /// demandé. On ne vise Drive qu'une fois l'accord donné.
  Future<BackupDestination> destination() async {
    final prefs = await SharedPreferences.getInstance();
    return BackupDestination.parse(prefs.getString(_kDestinationKey));
  }

  Future<void> setDestination(BackupDestination value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDestinationKey, value.name);
  }

  Future<BackupState> state() async {
    final prefs = await SharedPreferences.getInstance();
    return BackupState(
      lastSuccessAt: _readDate(prefs.getInt(_kLastSuccessKey)),
      lastAttemptAt: _readDate(prefs.getInt(_kLastAttemptKey)),
      consecutiveFailures: prefs.getInt(_kFailuresKey) ?? 0,
      firstFailureAt: _readDate(prefs.getInt(_kFirstFailureKey)),
      lastFallbackAt: _readDate(prefs.getInt(_kLastFallbackKey)),
    );
  }

  Future<void> saveState(BackupState value) async {
    final prefs = await SharedPreferences.getInstance();
    await _writeDate(prefs, _kLastSuccessKey, value.lastSuccessAt);
    await _writeDate(prefs, _kLastAttemptKey, value.lastAttemptAt);
    await prefs.setInt(_kFailuresKey, value.consecutiveFailures);
    await _writeDate(prefs, _kFirstFailureKey, value.firstFailureAt);
    await _writeDate(prefs, _kLastFallbackKey, value.lastFallbackAt);
  }

  /// Horodatages en millisecondes UTC plutôt qu'en texte : insensible au
  /// fuseau de l'appareil, qui peut changer en voyage sans que l'histoire des
  /// sauvegardes ait à en souffrir.
  static DateTime? _readDate(int? ms) => ms == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  static Future<void> _writeDate(
    SharedPreferences prefs,
    String key,
    DateTime? value,
  ) async {
    if (value == null) {
      await prefs.remove(key);
    } else {
      await prefs.setInt(key, value.toUtc().millisecondsSinceEpoch);
    }
  }
}
