import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/utils/media_expiry.dart';

void main() {
  const base = 'https://www.alanya237.com';
  DateTime t(String iso) => DateTime.parse(iso);

  group('partitionFromMediaUrl', () {
    test('lit la tranche dans une URL partitionnée', () {
      expect(
        partitionFromMediaUrl('$base/uploads/media/2026-08-24/images/media_51_1756000000000.jpg'),
        '2026-08-24',
      );
      expect(
        partitionFromMediaUrl('/uploads/media/2026-07-20/video/media_10_1.mp4'),
        '2026-07-20',
      );
    });

    test('null sur ce qui n\'est pas partitionné', () {
      // Adresse héritée d'avant la migration : le serveur la relaie, le client
      // n'a aucun moyen d'en déduire une date.
      expect(partitionFromMediaUrl('$base/uploads/media/images/media_51_1.jpg'), isNull);
      // Un avatar n'expire jamais.
      expect(partitionFromMediaUrl('$base/uploads/images/img_51_1.jpg'), isNull);
      expect(partitionFromMediaUrl(''), isNull);
      expect(partitionFromMediaUrl(null), isNull);
    });

    test('null sur une date qui n\'existe pas', () {
      // Bonne forme, jour inexistant : sans ce contrôle, DateTime.utc
      // normaliserait vers le 3 mars et l'échéance serait calculée de travers.
      expect(partitionFromMediaUrl('/uploads/media/2026-02-31/images/x.jpg'), isNull);
      expect(partitionFromMediaUrl('/uploads/media/2026-13-01/images/x.jpg'), isNull);
    });
  });

  group('partitionExpiresAt', () {
    test('tombe à D + rétention + 1 jour', () {
      // Le fichier le plus récent de la tranche du 20 est déposé juste avant
      // le 21 à 00:00Z ; avec 30 jours de rétention il doit vivre jusqu'au 20
      // août. Miroir exact de `partitionExpiresAtMs` côté serveur.
      expect(partitionExpiresAt('2026-07-20', 30), t('2026-08-20T00:00:00Z'));
      expect(partitionExpiresAt('2026-07-20', 1), t('2026-07-22T00:00:00Z'));
    });

    test('null sur une clé illisible', () {
      expect(partitionExpiresAt(null, 30), isNull);
      expect(partitionExpiresAt('images', 30), isNull);
      expect(partitionExpiresAt('2026-02-31', 30), isNull);
    });
  });

  group('isMediaExpired', () {
    const url = 'https://www.alanya237.com/uploads/media/2026-07-20/images/x.jpg';

    test('la frontière est celle de la partition', () {
      expect(
        isMediaExpired(url, retentionDays: 30, now: t('2026-08-19T23:59:59Z')),
        isFalse,
        reason: 'une seconde avant, la tranche tient encore',
      );
      expect(
        isMediaExpired(url, retentionDays: 30, now: t('2026-08-20T00:00:00Z')),
        isTrue,
        reason: 'à l\'instant pile, elle est tombée',
      );
    });

    test('aucune garantie ne peut être plus courte que la rétention annoncée', () {
      // Le média le plus ancien de la tranche vit rétention + 1 jour, le plus
      // récent exactement la rétention. Aucun ne vit moins.
      final debut = t('2026-07-20T00:00:00Z');
      final fin = t('2026-07-20T23:59:59Z');
      for (final depot in [debut, fin]) {
        final trenteJoursApres = depot.add(const Duration(days: 30));
        expect(
          isMediaExpired(url, retentionDays: 30, now: trenteJoursApres),
          isFalse,
          reason: 'un média déposé le $depot doit survivre 30 jours pleins',
        );
      }
    });

    test('prudent : false dès qu\'un doute existe', () {
      // Rétention pas encore apprise du serveur : on laisse la requête partir
      // plutôt que de masquer un média peut-être vivant.
      expect(isMediaExpired(url, retentionDays: null), isFalse);
      expect(isMediaExpired(url, retentionDays: 0), isFalse);
      // URL non partitionnée : impossible de savoir sans demander.
      expect(
        isMediaExpired('/uploads/media/images/x.jpg',
            retentionDays: 30, now: t('2030-01-01T00:00:00Z')),
        isFalse,
      );
      // Un avatar n'expire jamais.
      expect(
        isMediaExpired('/uploads/images/img_1_1.jpg',
            retentionDays: 30, now: t('2030-01-01T00:00:00Z')),
        isFalse,
      );
      expect(isMediaExpired(null, retentionDays: 30), isFalse);
    });

    test('une rétention longue garde tout vivant', () {
      // Réglage de mise en service : 365 jours, rien n'expire.
      expect(
        isMediaExpired(url, retentionDays: 365, now: t('2026-08-26T12:00:00Z')),
        isFalse,
      );
    });

    test('le contrat serveur est celui attendu', () {
      expect(kMediaExpiredError, 'MEDIA_EXPIRED');
      expect(kMediaGoneStatus, 410);
    });
  });
}
