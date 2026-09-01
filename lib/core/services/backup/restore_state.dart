import 'package:shared_preferences/shared_preferences.dart';

/// Où en est la restauration sur cet appareil.
///
/// L'état est persisté **hors de la base**, puisque la base est justement ce
/// qu'on est en train de remplacer.
enum RestoreStage {
  /// On n'a pas encore cherché de sauvegarde.
  unknown,

  /// Une sauvegarde existe, l'inscrit n'a pas tranché.
  offered,

  /// Écriture commencée. **La base est dans un état intermédiaire.**
  inProgress,

  /// La base restaurée est écrite à côté et attend d'être mise en place.
  ///
  /// L'échange ne peut pas avoir lieu pendant que l'application tourne :
  /// `AppDatabase` est un champ `late final` du démarrage, on ne remplace pas
  /// son instance à chaud. Le fichier est donc posé, puis mis en place au
  /// prochain lancement, **avant** que quoi que ce soit n'ouvre la base — le
  /// même procédé qu'une mise à jour de programme.
  pendingSwap,

  /// Terminée et vérifiée.
  done,

  /// L'inscrit a refusé. On ne repropose plus au démarrage.
  skipped;

  static RestoreStage parse(String? raw) => RestoreStage.values
      .firstWhere((s) => s.name == raw, orElse: () => RestoreStage.unknown);
}

/// Persistance de l'étape de restauration.
///
/// ── Pourquoi cet état est indispensable ──
///
/// Si l'application est tuée au milieu de l'écriture, la base contient des
/// messages pour *certaines* conversations seulement. Au redémarrage, le
/// rattrapage de synchronisation les considère comme complètes — puisqu'elles
/// ont un message serveur — et les saute définitivement. **Les trous
/// deviennent permanents, et silencieux.**
///
/// C'est précisément parce que la logique de curseur est correcte qu'un état
/// intermédiaire est toxique. D'où la règle sans nuance de
/// [needsRecoveryAfterCrash] : trouver [RestoreStage.inProgress] au démarrage
/// impose de repartir de zéro.
class RestoreStateStore {
  static const String _kStageKey = 'restore_stage';
  static const String _kStartedAtKey = 'restore_started_at';

  const RestoreStateStore();

  Future<RestoreStage> stage() async {
    final prefs = await SharedPreferences.getInstance();
    return RestoreStage.parse(prefs.getString(_kStageKey));
  }

  Future<void> setStage(RestoreStage value, {DateTime? at}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kStageKey, value.name);
    if (value == RestoreStage.inProgress ||
        value == RestoreStage.pendingSwap) {
      await prefs.setInt(
        _kStartedAtKey,
        (at ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
      );
    } else {
      await prefs.remove(_kStartedAtKey);
    }
  }

  /// Une restauration a-t-elle été interrompue en cours d'écriture ?
  ///
  /// La seule réponse acceptable à « oui » est de vider la base et de
  /// reproposer : une demi-restauration est pire que pas de restauration.
  Future<bool> needsRecoveryAfterCrash() async =>
      await stage() == RestoreStage.inProgress;

  /// Une base restaurée attend-elle d'être mise en place au démarrage ?
  Future<bool> hasPendingSwap() async =>
      await stage() == RestoreStage.pendingSwap;

  /// Faut-il proposer une restauration au démarrage ?
  ///
  /// Non après un refus explicite : lui reposer la question à chaque
  /// démarrage transformerait un choix en harcèlement.
  Future<bool> shouldOffer() async {
    final current = await stage();
    return current == RestoreStage.unknown || current == RestoreStage.offered;
  }
}
