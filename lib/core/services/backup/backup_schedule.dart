/// Fréquence de sauvegarde, au choix de l'inscrit.
///
/// C'est la convention que WhatsApp a installée : il saura la lire sans
/// explication.
enum BackupFrequency {
  daily,
  weekly,
  monthly,

  /// Aucune sauvegarde automatique. La sauvegarde manuelle reste possible.
  never;

  Duration? get interval => switch (this) {
        BackupFrequency.daily => const Duration(days: 1),
        BackupFrequency.weekly => const Duration(days: 7),
        BackupFrequency.monthly => const Duration(days: 30),
        BackupFrequency.never => null,
      };

  static BackupFrequency parse(String? raw) => BackupFrequency.values
      .firstWhere((f) => f.name == raw, orElse: () => BackupFrequency.weekly);
}

/// Ce que l'appareil sait de ses propres sauvegardes.
///
/// Cet état est **propre à l'appareil** : il décrit les tentatives faites
/// depuis ce téléphone-ci, pas l'état du compte. Il n'a donc rien à voyager
/// dans une sauvegarde.
class BackupState {
  /// Dernier dépôt réussi **à la destination choisie**. Une copie de secours
  /// n'y touche pas : c'est cette date, et elle seule, qui fait taire l'alerte.
  final DateTime? lastSuccessAt;
  final DateTime? lastAttemptAt;
  final int consecutiveFailures;

  /// Début de la série d'échecs en cours, effacé au premier succès.
  ///
  /// **Sans lui, l'alerte ne part jamais** quand aucune sauvegarde n'a jamais
  /// abouti : elle se mesurait sur la *dernière tentative*, que chaque réessai
  /// rafraîchit. Quelqu'un qui échoue tous les jours depuis six mois n'était
  /// donc averti… que s'il arrêtait d'essayer pendant trois jours. Le critère
  /// était inversé.
  final DateTime? firstFailureAt;

  /// Dernière copie écrite en local **faute de mieux**, alors que Drive était
  /// la destination choisie.
  ///
  /// Sert à deux choses : afficher le bandeau qui dit franchement où sont les
  /// données, et éviter de réécrire un mégaoctet toutes les quinze minutes
  /// pendant que le réessai s'acharne sur un Drive injoignable.
  final DateTime? lastFallbackAt;

  const BackupState({
    this.lastSuccessAt,
    this.lastAttemptAt,
    this.consecutiveFailures = 0,
    this.firstFailureAt,
    this.lastFallbackAt,
  });

  /// Dépôt réussi à la destination choisie. La copie de secours est oubliée :
  /// elle n'a plus rien à signaler, et le bandeau doit disparaître.
  BackupState afterSuccess(DateTime at) => BackupState(
        lastSuccessAt: at,
        lastAttemptAt: at,
        consecutiveFailures: 0,
      );

  BackupState afterFailure(DateTime at) => BackupState(
        lastSuccessAt: lastSuccessAt,
        lastAttemptAt: at,
        consecutiveFailures: consecutiveFailures + 1,
        firstFailureAt: firstFailureAt ?? at,
        lastFallbackAt: lastFallbackAt,
      );

  /// Oublie la copie de secours, sans toucher au reste.
  ///
  /// Appelé quand l'inscrit change de destination : le bandeau parle d'un
  /// échec survenu sous une autre destination, il n'a plus rien à annoncer.
  /// Sans cela, un aller-retour Drive → appareil → Drive ressuscitait un
  /// avertissement vieux de plusieurs semaines, sans qu'aucune tentative
  /// n'ait eu lieu entre-temps.
  BackupState withoutFallback() => BackupState(
        lastSuccessAt: lastSuccessAt,
        lastAttemptAt: lastAttemptAt,
        consecutiveFailures: consecutiveFailures,
        firstFailureAt: firstFailureAt,
      );

  /// Drive était visé, il n'a pas répondu, une copie locale a été écrite.
  ///
  /// **Compté comme un échec**, et c'est tout l'intérêt : les données sont
  /// sauvées, mais la destination voulue a été manquée. Le réessai reprend, et
  /// l'alerte des trois jours reste armée. Compter cela comme un succès, ce
  /// que faisait le code précédent, revenait à débrancher l'alarme parce que
  /// le filet avait fonctionné.
  BackupState afterFallback(DateTime at) => BackupState(
        lastSuccessAt: lastSuccessAt,
        lastAttemptAt: at,
        consecutiveFailures: consecutiveFailures + 1,
        firstFailureAt: firstFailureAt ?? at,
        lastFallbackAt: at,
      );
}

/// Décide **quand** sauvegarder et **quand le dire**.
///
/// Volontairement sans état ni dépendance : elle reçoit tout ce dont elle a
/// besoin et rend une décision. C'est ce qui permet d'éprouver des scénarios
/// de plusieurs semaines en quelques millisecondes, sans horloge à truquer ni
/// réseau à simuler.
class BackupSchedulePolicy {
  /// Délai avant de retenter après un échec. Croît avec le nombre d'échecs
  /// consécutifs pour ne pas s'acharner sur un réseau coupé ou un quota plein,
  /// et se plafonne pour ne jamais renoncer tout à fait.
  static const List<Duration> retryBackoff = [
    Duration(minutes: 15),
    Duration(hours: 1),
    Duration(hours: 6),
    Duration(hours: 12),
  ];

  /// Marge accordée avant de signaler visiblement une série d'échecs.
  ///
  /// Elle s'ajoute à l'intervalle choisi plutôt que d'être un délai absolu :
  /// alerter au bout de trois jours un inscrit qui a choisi « mensuelle »
  /// serait absurde.
  static const Duration alertGrace = Duration(days: 3);

  const BackupSchedulePolicy();

  /// Une sauvegarde automatique doit-elle partir maintenant ?
  bool shouldRun({
    required DateTime now,
    required BackupFrequency frequency,
    required BackupState state,
    required bool isUnmetered,
  }) {
    final interval = frequency.interval;
    if (interval == null) return false;

    // Le garde-fou réseau : la sauvegarde ne doit jamais consommer le forfait
    // de l'inscrit à son insu. `ConnectivityService` distingue déjà le Wi-Fi
    // et l'ethernet des données mobiles.
    if (!isUnmetered) return false;

    // Un échec récent : on laisse passer le délai de reprise plutôt que de
    // relancer en boucle sur un réseau coupé.
    final attempt = state.lastAttemptAt;
    if (state.consecutiveFailures > 0 && attempt != null) {
      final wait = retryBackoff[
          (state.consecutiveFailures - 1).clamp(0, retryBackoff.length - 1)];
      if (now.difference(attempt) < wait) return false;
    }

    final last = state.lastSuccessAt;
    // Jamais sauvegardé : c'est le moment le plus utile pour le faire.
    if (last == null) return true;
    return now.difference(last) >= interval;
  }

  /// Faut-il **signaler visiblement** que les sauvegardes n'aboutissent plus ?
  ///
  /// Alerter à chaque coupure réseau apprendrait à l'inscrit à ignorer nos
  /// alertes — et il les ignorerait aussi le jour où elles comptent. On ne
  /// parle donc qu'après une série, et jamais si la sauvegarde automatique est
  /// désactivée : il l'a voulu ainsi.
  bool shouldAlert({
    required DateTime now,
    required BackupFrequency frequency,
    required BackupState state,
  }) {
    final interval = frequency.interval;
    if (interval == null) return false;

    final last = state.lastSuccessAt;
    if (last == null) {
      // Jamais réussi : on ne parle qu'après de vraies tentatives, pour ne pas
      // accueillir un nouvel inscrit par un avertissement.
      //
      // Mesuré depuis le DÉBUT de la série, et non depuis la dernière
      // tentative : le réessai repoussant sans cesse cette dernière, le délai
      // n'était jamais atteint tant qu'on continuait d'essayer. L'alerte ne
      // partait donc que si l'on renonçait — exactement l'inverse.
      final since = state.firstFailureAt ?? state.lastAttemptAt;
      if (since == null || state.consecutiveFailures == 0) return false;
      return now.difference(since) >= alertGrace;
    }
    return now.difference(last) >= interval + alertGrace;
  }

  /// Quand la prochaine sauvegarde est attendue, pour l'écran de réglages.
  DateTime? nextAttempt({
    required BackupFrequency frequency,
    required BackupState state,
  }) {
    final interval = frequency.interval;
    if (interval == null) return null;
    final last = state.lastSuccessAt;
    return last?.add(interval);
  }
}
