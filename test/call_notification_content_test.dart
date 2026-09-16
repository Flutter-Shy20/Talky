// Deux notifications s'affichaient pendant chaque appel : Android en impose une
// par service au premier plan, et il en démarrait deux. Celle du plugin est
// désormais masquée, et la nôtre reste seule — elle doit donc porter ce que
// l'autre portait. Ces tests tiennent les deux règles qui ne vont pas de soi.

import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_notification_content.dart';

void main() {
  group('titre de la notification', () {
    test('le nom de l\'interlocuteur quand on l\'a', () {
      expect(
        callNotificationTitle(displayName: 'Awa Ndiaye', fallback: 'Appel'),
        'Awa Ndiaye',
      );
    });

    test('un nom vide ou blanc retombe sur le libellé générique', () {
      for (final vide in ['', '   ', '\n']) {
        expect(
          callNotificationTitle(displayName: vide, fallback: 'Appel en cours…'),
          'Appel en cours…',
          reason: 'une notification sans titre se réduit à son icône : '
              'plus personne ne sait ce qui tourne',
        );
      }
    });

    test('les espaces autour du nom ne se voient pas', () {
      expect(
        callNotificationTitle(displayName: '  Awa  ', fallback: 'Appel'),
        'Awa',
      );
    });
  });

  group('chronomètre', () {
    test('rien tant que l\'appel sonne', () {
      expect(
        callNotificationUsesChronometer(0),
        isFalse,
        reason: 'la notification est posée avant la réponse : chez l\'appelant '
            'le chronomètre aurait compté toute la sonnerie',
      );
    });

    test('il part à la connexion', () {
      expect(
        callNotificationUsesChronometer(DateTime.now().millisecondsSinceEpoch),
        isTrue,
      );
    });

    test('un instant absurde ne le lance pas', () {
      expect(callNotificationUsesChronometer(-1), isFalse);
    });
  });
}
