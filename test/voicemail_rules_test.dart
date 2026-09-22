import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/voicemail_rules.dart';
import 'package:talky_flutter/talky_models.dart';

VoicemailSchedule creneau({
  bool active = false,
  DateTime? activeUntil,
  bool enabled = false,
}) =>
    VoicemailSchedule(
      enabled: enabled,
      active: active,
      activeUntil: activeUntil,
    );

void main() {
  group('échéances de l\'activation rapide', () {
    test('une heure et quatre heures partent de maintenant', () {
      final now = DateTime(2026, 9, 21, 14, 30);
      expect(
        quickDeadline(VoicemailQuickDuration.oneHour, now: now),
        DateTime(2026, 9, 21, 15, 30),
      );
      expect(
        quickDeadline(VoicemailQuickDuration.fourHours, now: now),
        DateTime(2026, 9, 21, 18, 30),
      );
    });

    test('après 8 h, la bascule matinale vise le lendemain', () {
      final now = DateTime(2026, 9, 21, 14, 30);
      expect(
        quickDeadline(VoicemailQuickDuration.nextMorning, now: now),
        DateTime(2026, 9, 22, 8, 0),
      );
    });

    test('avant 8 h, elle vise le matin même', () {
      // À 2 h du matin, viser le lendemain enfermerait l'utilisateur trente
      // heures sans qu'il l'ait demandé.
      final now = DateTime(2026, 9, 21, 2, 0);
      expect(
        quickDeadline(VoicemailQuickDuration.nextMorning, now: now),
        DateTime(2026, 9, 21, 8, 0),
      );
    });

    test('à 8 h pile, on passe au lendemain', () {
      final now = DateTime(2026, 9, 21, 8, 0);
      expect(
        quickDeadline(VoicemailQuickDuration.nextMorning, now: now),
        DateTime(2026, 9, 22, 8, 0),
        reason: 'une échéance déjà atteinte n\'activerait rien du tout',
      );
    });

    test('un changement de mois ne casse pas le calcul', () {
      final now = DateTime(2026, 9, 30, 23, 0);
      expect(
        quickDeadline(VoicemailQuickDuration.nextMorning, now: now),
        DateTime(2026, 10, 1, 8, 0),
      );
    });
  });

  group('plafond des 24 heures', () {
    final now = DateTime(2026, 9, 22, 14, 0);

    test('une échéance dans la journée passe', () {
      expect(isWithinMaxDuration(now.add(const Duration(hours: 4)), now: now), isTrue);
      expect(isWithinMaxDuration(now.add(const Duration(hours: 23, minutes: 59)), now: now), isTrue);
    });

    test('exactement 24 heures passe encore', () {
      expect(isWithinMaxDuration(now.add(const Duration(hours: 24)), now: now), isTrue);
    });

    test('au-delà, non — une durée qu\'on peut pousser redevient un oubli', () {
      expect(isWithinMaxDuration(now.add(const Duration(hours: 25)), now: now), isFalse);
      expect(isWithinMaxDuration(now.add(const Duration(days: 7)), now: now), isFalse);
    });

    test('une échéance déjà passée n\'activerait rien', () {
      expect(isWithinMaxDuration(now.subtract(const Duration(minutes: 1)), now: now), isFalse);
    });

    test('les trois échéances rapides tiennent toutes dans le plafond', () {
      // « Jusqu'à demain 8 h » réglé à 7 h du matin dépasserait 24 h si la
      // bascule matinale visait le lendemain plutôt que la prochaine occurrence.
      for (final heure in [0, 2, 7, 8, 14, 23]) {
        final t = DateTime(2026, 9, 22, heure, 30);
        for (final d in VoicemailQuickDuration.values) {
          expect(
            isWithinMaxDuration(quickDeadline(d, now: t), now: t),
            isTrue,
            reason: 'à ${heure}h30, $d',
          );
        }
      }
    });
  });

  group('forme des écritures', () {
    test('l\'activation envoie une échéance en UTC', () {
      final local = DateTime(2026, 9, 21, 15, 30);
      final patch = activatePatch(local);
      expect(patch.keys, ['untilAt']);
      expect(
        DateTime.parse(patch['untilAt'] as String),
        local.toUtc(),
        reason: 'untilAt est un instant absolu : le serveur ne le re-dérive '
            'jamais, donc l\'appareil doit l\'envoyer déjà converti',
      );
      expect((patch['untilAt'] as String).endsWith('Z'), isTrue);
    });

    test('« Désactiver » éteint les DEUX mécanismes', () {
      final patch = disablePatch();
      expect(patch['untilAt'], isNull);
      expect(
        patch['enabled'],
        isFalse,
        reason: 'n\'effacer que untilAt laisserait le bandeau en place si un '
            'créneau récurrent est en cours : le bouton paraîtrait cassé',
      );
    });
  });

  group('affichage du bandeau', () {
    final now = DateTime.utc(2026, 9, 21, 12, 0);

    test('rien à montrer sans planification ni activité', () {
      expect(shouldShowBanner(null, now: now), isFalse);
      expect(shouldShowBanner(creneau(active: false), now: now), isFalse);
    });

    test('actif avec une échéance à venir : on montre', () {
      final s = creneau(active: true, activeUntil: DateTime.utc(2026, 9, 21, 17));
      expect(shouldShowBanner(s, now: now), isTrue);
    });

    test('actif sans échéance : on montre quand même', () {
      // Créneau couvrant la journée entière : pas d'heure de fin calculable.
      expect(shouldShowBanner(creneau(active: true), now: now), isTrue);
      expect(deadlineLabel(null), isNull);
    });

    test('l\'échéance passée masque le bandeau sans attendre le serveur', () {
      final s = creneau(active: true, activeUntil: DateTime.utc(2026, 9, 21, 11));
      expect(
        shouldShowBanner(s, now: now),
        isFalse,
        reason: 'le serveur a répondu « actif » à la lecture ; sans cette '
            'comparaison le bandeau survivrait jusqu\'au prochain réseau',
      );
    });
  });

  group('minuteur de ré-évaluation', () {
    final now = DateTime.utc(2026, 9, 21, 12, 0);

    test('il vise l\'échéance, pas un battement régulier', () {
      final s = creneau(active: true, activeUntil: DateTime.utc(2026, 9, 21, 17));
      final delai = bannerRefreshDelay(s, now: now);
      expect(delai, isNotNull);
      expect(delai!.inMinutes, 300);
      expect(
        delai.inSeconds - const Duration(hours: 5).inSeconds,
        1,
        reason: 'une seconde de marge, pour ne pas se réveiller juste avant la '
            'bascule et devoir reprogrammer',
      );
    });

    test('rien à programmer quand il n\'y a pas d\'échéance', () {
      expect(bannerRefreshDelay(null, now: now), isNull);
      expect(bannerRefreshDelay(creneau(active: false), now: now), isNull);
      expect(bannerRefreshDelay(creneau(active: true), now: now), isNull);
    });

    test('une échéance déjà passée ne programme rien', () {
      final s = creneau(active: true, activeUntil: DateTime.utc(2026, 9, 21, 11));
      expect(bannerRefreshDelay(s, now: now), isNull);
    });
  });

  group('libellé de l\'échéance', () {
    test('formaté en heure locale sur deux chiffres', () {
      final fin = DateTime(2026, 9, 21, 9, 5);
      expect(deadlineLabel(fin.toUtc()), '09:05');
    });

    test('minuit s\'écrit 00:00', () {
      expect(deadlineLabel(DateTime(2026, 9, 21, 0, 0).toUtc()), '00:00');
    });
  });
}
