import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/backup/backup_schedule.dart';
import 'package:talky_flutter/core/services/backup/backup_target.dart';

/// Politique de planification : quand sauvegarder, et quand le dire.
///
/// Toute la logique est sans état ni dépendance, ce qui permet de rejouer ici
/// des scénarios de plusieurs semaines sans truquer d'horloge ni simuler de
/// réseau.
void main() {
  const policy = BackupSchedulePolicy();
  final now = DateTime.utc(2026, 8, 31, 21);

  bool run({
    BackupFrequency frequency = BackupFrequency.daily,
    BackupState state = const BackupState(),
    bool unmetered = true,
    DateTime? at,
  }) =>
      policy.shouldRun(
        now: at ?? now,
        frequency: frequency,
        state: state,
        isUnmetered: unmetered,
      );

  bool alert({
    BackupFrequency frequency = BackupFrequency.daily,
    BackupState state = const BackupState(),
    DateTime? at,
  }) =>
      policy.shouldAlert(
        now: at ?? now,
        frequency: frequency,
        state: state,
      );

  group('déclenchement', () {
    test('jamais sauvegardé : on part tout de suite', () {
      // C'est le moment où une sauvegarde est la plus utile.
      expect(run(), isTrue);
    });

    test('« jamais » ne déclenche rien, quoi qu\'il arrive', () {
      expect(run(frequency: BackupFrequency.never), isFalse);
      expect(
        run(
          frequency: BackupFrequency.never,
          state: BackupState(lastSuccessAt: DateTime.utc(2020)),
        ),
        isFalse,
      );
    });

    test('les données mobiles ne déclenchent jamais une sauvegarde', () {
      // Elle ne doit pas consommer le forfait de l'inscrit à son insu.
      expect(run(unmetered: false), isFalse);
    });

    test('l\'intervalle est respecté', () {
      final hier = BackupState(lastSuccessAt: now.subtract(
        const Duration(hours: 23),
      ));
      expect(run(state: hier), isFalse);

      final avantHier = BackupState(lastSuccessAt: now.subtract(
        const Duration(hours: 25),
      ));
      expect(run(state: avantHier), isTrue);
    });

    test('l\'intervalle suit la fréquence choisie', () {
      final ilYaDixJours = BackupState(
        lastSuccessAt: now.subtract(const Duration(days: 10)),
      );
      expect(run(frequency: BackupFrequency.weekly, state: ilYaDixJours),
          isTrue);
      expect(run(frequency: BackupFrequency.monthly, state: ilYaDixJours),
          isFalse);
    });
  });

  group('reprise après échec', () {
    test('un échec récent fait patienter au lieu de s\'acharner', () {
      final juste = BackupState(
        lastAttemptAt: now.subtract(const Duration(minutes: 5)),
        consecutiveFailures: 1,
      );
      expect(run(state: juste), isFalse);

      final plusTard = BackupState(
        lastAttemptAt: now.subtract(const Duration(minutes: 20)),
        consecutiveFailures: 1,
      );
      expect(run(state: plusTard), isTrue);
    });

    test('le délai de reprise s\'allonge avec les échecs', () {
      // Réseau coupé ou quota plein : inutile de repartir toutes les quinze
      // minutes pendant des jours.
      final quatreEchecs = BackupState(
        lastAttemptAt: now.subtract(const Duration(hours: 2)),
        consecutiveFailures: 4,
      );
      expect(run(state: quatreEchecs), isFalse);

      final apres = BackupState(
        lastAttemptAt: now.subtract(const Duration(hours: 13)),
        consecutiveFailures: 4,
      );
      expect(run(state: apres), isTrue);
    });

    test('le délai se plafonne : on ne renonce jamais tout à fait', () {
      // Même après cinquante échecs, une tentative par demi-journée.
      final beaucoup = BackupState(
        lastAttemptAt: now.subtract(const Duration(hours: 13)),
        consecutiveFailures: 50,
      );
      expect(run(state: beaucoup), isTrue);
    });

    test('un succès remet le compteur d\'échecs à zéro', () {
      final state =
          const BackupState(consecutiveFailures: 7).afterSuccess(now);
      expect(state.consecutiveFailures, 0);
      expect(state.lastSuccessAt, now);
    });
  });

  group('alerte', () {
    test('une coupure passagère ne dit rien', () {
      // Alerter à chaque échec réseau apprendrait à l'inscrit à ignorer nos
      // alertes — y compris le jour où elles comptent.
      final hier = BackupState(
        lastSuccessAt: now.subtract(const Duration(days: 1)),
        lastAttemptAt: now,
        consecutiveFailures: 2,
      );
      expect(alert(state: hier), isFalse);
    });

    test('plusieurs jours sans succès finissent par se dire', () {
      final vieux = BackupState(
        lastSuccessAt: now.subtract(const Duration(days: 5)),
        lastAttemptAt: now,
        consecutiveFailures: 9,
      );
      expect(alert(state: vieux), isTrue);
    });

    test('le seuil suit la fréquence, il n\'est pas absolu', () {
      // Alerter au bout de trois jours quelqu'un qui a choisi « mensuelle »
      // serait absurde.
      final ilYaCinqJours = BackupState(
        lastSuccessAt: now.subtract(const Duration(days: 5)),
        lastAttemptAt: now,
        consecutiveFailures: 3,
      );
      expect(alert(frequency: BackupFrequency.daily, state: ilYaCinqJours),
          isTrue);
      expect(alert(frequency: BackupFrequency.monthly, state: ilYaCinqJours),
          isFalse);
    });

    test('« jamais » n\'alerte pas : il l\'a voulu ainsi', () {
      final vieux = BackupState(
        lastSuccessAt: now.subtract(const Duration(days: 400)),
        lastAttemptAt: now,
        consecutiveFailures: 30,
      );
      expect(alert(frequency: BackupFrequency.never, state: vieux), isFalse);
    });

    test('un inscrit tout neuf n\'est pas accueilli par un avertissement', () {
      // Aucune sauvegarde, aucune tentative : rien à signaler.
      expect(alert(state: const BackupState()), isFalse);

      // Des tentatives qui échouent depuis plusieurs jours, en revanche, oui.
      final jamaisReussi = BackupState(
        lastAttemptAt: now.subtract(const Duration(days: 4)),
        consecutiveFailures: 5,
      );
      expect(alert(state: jamaisReussi), isTrue);
    });
  });

  test('une fréquence inconnue retombe sur hebdomadaire', () {
    // Valeur écrite par une version plus récente, ou préférence corrompue :
    // on ne doit ni planter ni cesser silencieusement de sauvegarder.
    expect(BackupFrequency.parse('trimestrielle'), BackupFrequency.weekly);
    expect(BackupFrequency.parse(null), BackupFrequency.weekly);
    expect(BackupFrequency.parse('daily'), BackupFrequency.daily);
  });

  group('sauvegarde de secours', () {
    // Drive visé, injoignable, copie locale écrite. Les données sont sauvées ;
    // la destination voulue a été manquée. Les deux doivent être vrais en même
    // temps dans l'état, sinon l'un des deux se perd.
    final apres = const BackupState().afterFallback(now);

    test('compte comme un échec, pas comme un succès', () {
      expect(apres.consecutiveFailures, 1);
      expect(apres.lastSuccessAt, isNull);
      expect(apres.lastAttemptAt, now);
    });

    test('retient la date, pour le bandeau et pour ne pas réécrire en boucle',
        () {
      expect(apres.lastFallbackAt, now);
    });

    test('ne piétine pas le dernier vrai succès', () {
      final avant = DateTime.utc(2026, 8, 20);
      final etat = BackupState(lastSuccessAt: avant).afterFallback(now);
      expect(etat.lastSuccessAt, avant);
      expect(etat.lastFallbackAt, now);
    });

    test('un succès à la destination voulue fait taire le bandeau', () {
      final etat = BackupState(lastFallbackAt: now).afterSuccess(now);
      expect(etat.lastFallbackAt, isNull);
      expect(etat.consecutiveFailures, 0);
    });

    test('un échec sec conserve la date de secours', () {
      // Le réessai qui échoue sans rien écrire ne doit pas faire disparaître
      // le bandeau : la copie locale, elle, est toujours là.
      final etat = BackupState(lastFallbackAt: now).afterFailure(now);
      expect(etat.lastFallbackAt, now);
    });

    test('LA RÉGRESSION : des secours à répétition finissent par alerter', () {
      // Jamais aucun dépôt Drive, six secours de suite, quotidien.
      var etat = const BackupState();
      var t = now;
      for (var i = 0; i < 6; i++) {
        etat = etat.afterFallback(t);
        t = t.add(const Duration(days: 1));
      }
      expect(etat.consecutiveFailures, 6);
      // Avec l'ancien comportement — secours compté comme succès — cette
      // assertion était fausse, et le restait indéfiniment.
      expect(alert(state: etat, at: t), isTrue);
    });

    test('un seul secours ne réveille personne', () {
      // Une coupure réseau isolée est normale. Alerter là-dessus apprendrait à
      // ignorer l'alerte, y compris le jour où elle compte.
      final etat = const BackupState().afterFallback(now);
      expect(alert(state: etat, at: now.add(const Duration(hours: 6))), isFalse);
    });
  });

  group("alerte quand rien n'a jamais abouti", () {
    test('trois jours après le DÉBUT de la série, on parle', () {
      var etat = const BackupState();
      var t = now;
      // Quatre jours d'échecs quotidiens : on essaie tous les jours, donc la
      // dernière tentative a toujours moins de 24 h.
      for (var i = 0; i < 4; i++) {
        etat = etat.afterFailure(t);
        t = t.add(const Duration(days: 1));
      }
      expect(etat.firstFailureAt, now);
      expect(alert(state: etat, at: t), isTrue);
    });

    test('le premier jour, on se tait', () {
      final etat = const BackupState().afterFailure(now);
      expect(alert(state: etat, at: now.add(const Duration(hours: 20))),
          isFalse);
    });

    test('un succès referme la série', () {
      final etat = const BackupState().afterFailure(now).afterSuccess(now);
      expect(etat.firstFailureAt, isNull);
      expect(etat.consecutiveFailures, 0);
    });

    test('la série survit aux réessais : sa date ne bouge pas', () {
      final etat = const BackupState()
          .afterFailure(now)
          .afterFailure(now.add(const Duration(hours: 1)))
          .afterFailure(now.add(const Duration(hours: 7)));
      expect(etat.firstFailureAt, now, reason: 'le début de série est figé');
      expect(etat.lastAttemptAt, now.add(const Duration(hours: 7)));
    });
  });

  group('destination', () {
    test("par défaut l'appareil, jamais Drive", () {
      // Viser Drive sans autorisation ferait échouer chaque sauvegarde et
      // afficher un bandeau d'alerte à quelqu'un qui n'a rien demandé.
      expect(BackupDestination.parse(null), BackupDestination.device);
      expect(BackupDestination.parse('inconnu'), BackupDestination.device);
    });

    test('relit ce qui a été écrit', () {
      for (final d in BackupDestination.values) {
        expect(BackupDestination.parse(d.name), d);
      }
    });
  });

  group('changement de destination', () {
    test('oublie la copie de secours, garde le reste', () {
      // Le bandeau parle d'un échec survenu sous l'ANCIENNE destination : le
      // laisser le ferait ressusciter après un aller-retour, sans qu'aucune
      // tentative n'ait eu lieu entre-temps.
      final avant = BackupState(
        lastSuccessAt: DateTime.utc(2026, 8, 20),
        lastAttemptAt: now,
        consecutiveFailures: 3,
        firstFailureAt: DateTime.utc(2026, 8, 25),
        lastFallbackAt: now,
      );
      final apres = avant.withoutFallback();
      expect(apres.lastFallbackAt, isNull);
      expect(apres.lastSuccessAt, avant.lastSuccessAt);
      expect(apres.consecutiveFailures, 3);
      expect(apres.firstFailureAt, avant.firstFailureAt);
      expect(apres.lastAttemptAt, now);
    });
  });
}
