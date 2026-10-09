import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talky_flutter/core/services/billing/entitlement_service.dart';
import 'package:talky_flutter/core/services/billing/entitlements.dart';
import 'package:talky_flutter/core/services/media_expiry_policy.dart';
import 'package:talky_flutter/core/utils/media_upload_limits.dart';
import 'package:talky_flutter/talky_api_client.dart';

/// Charge utile telle que la rend le serveur (rules.js, decideEntitlements).
Map<String, dynamic> _payload({
  String phase = 'paid',
  Map<String, bool>? features,
  Map<String, dynamic>? period,
  String validUntil = '2026-10-10T00:00:00.000Z',
}) =>
    {
      'phase': phase,
      'graceUntil': null,
      'period': period,
      'upcoming': null,
      'exempt': false,
      'features': features ??
          {
            'translation': false,
            'backup': false,
            'trusted_trips': false,
            'list_ringtones': false,
            'style': false,
            'verified_badge': false,
          },
      'validUntil': validUntil,
    };

const int _mo = 1024 * 1024;

void main() {
  group('Entitlements', () {
    test('sans droits connus, tout est permis', () {
      const e = Entitlements.unrestricted;
      expect(e.known, isFalse);
      for (final f in PlusFeature.values) {
        expect(e.has(f), isTrue, reason: f.code);
      }
      expect(Entitlements.fromJson(null).known, isFalse);
    });

    test('phase payante sans abonnement : fermé', () {
      final e = Entitlements.fromJson(_payload());
      expect(e.phase, PlusPhase.paid);
      expect(e.has(PlusFeature.translation), isFalse);
      expect(e.has(PlusFeature.trustedTrips), isFalse);
      expect(e.isSubscribed, isFalse);
    });

    test('abonné : ce que le plan ouvre, et la période', () {
      final e = Entitlements.fromJson(_payload(
        features: {'translation': true, 'backup': true, 'style': false},
        period: {
          'plan': 'plus_annuel',
          'startsAt': '2026-10-10T00:00:00.000Z',
          'endsAt': '2027-10-10T00:00:00.000Z',
          'source': 0,
          'autoRenew': true,
        },
      ));
      expect(e.has(PlusFeature.translation), isTrue);
      expect(e.has(PlusFeature.style), isFalse);
      expect(e.isSubscribed, isTrue);
      expect(e.period!.plan, 'plus_annuel');
      expect(e.period!.autoRenew, isTrue);
      expect(e.period!.endsAt, DateTime.utc(2027, 10, 10));
    });

    test('une fonctionnalité que le serveur ne connaît pas reste ouverte', () {
      final e = Entitlements.fromJson(_payload(features: {'translation': false}));
      expect(e.has(PlusFeature.listRingtones), isTrue);
    });

    test('validUntil dépassé : périmé, mais rien ne se ferme pour autant', () {
      final e = Entitlements.fromJson(
        _payload(features: {'translation': true}, validUntil: '2026-09-01T00:00:00.000Z'),
      );
      expect(e.isStale(DateTime.utc(2026, 9, 2)), isTrue);
      expect(e.has(PlusFeature.translation), isTrue);
      expect(Entitlements.unrestricted.isStale(DateTime.utc(2100)), isFalse);
    });

    test('aller-retour par le cache', () {
      final e = Entitlements.fromJson(_payload(
        phase: 'grace',
        features: {'translation': true},
        period: {'plan': 'plus_mensuel', 'endsAt': '2026-11-17T00:00:00.000Z'},
      ));
      final back = Entitlements.fromJson(e.toJson());
      expect(back.phase, PlusPhase.grace);
      expect(back.has(PlusFeature.translation), isTrue);
      expect(back.period!.plan, 'plus_mensuel');
      expect(back.validUntil, e.validUntil);
    });
  });

  group('EntitlementService', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('le profil sans clé entitlements laisse tout ouvert', () async {
      final s = EntitlementService(api: TalkyApiClient());
      await s.applyFromProfile({'alanyaID': 7});
      expect(s.current.known, isFalse);
      expect(EntitlementService.allows(PlusFeature.backup), isTrue);
    });

    test('les droits survivent au redémarrage, pas à la déconnexion', () async {
      final a = EntitlementService(api: TalkyApiClient());
      await a.applyFromProfile({'entitlements': _payload()});
      expect(a.has(PlusFeature.translation), isFalse);

      final b = EntitlementService(api: TalkyApiClient());
      await b.loadFromCache();
      expect(b.current.known, isTrue);
      expect(EntitlementService.allows(PlusFeature.translation), isFalse);

      await b.clear();
      final c = EntitlementService(api: TalkyApiClient());
      await c.loadFromCache();
      expect(c.current.known, isFalse);
    });
  });

  // Durée pendant laquelle CE compte peut télécharger un média de discussion :
  // c'est elle que l'app applique pour afficher « Média expiré ».
  group('conservation des médias', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      MediaExpiryPolicy.resetForTests();
    });

    test('lue dans les droits, gardée par le cache', () {
      final e = Entitlements.fromJson({..._payload(), 'mediaRetentionDays': 365});
      expect(e.mediaRetentionDays, 365);
      expect(Entitlements.fromJson(e.toJson()).mediaRetentionDays, 365);
      expect(Entitlements.fromJson(_payload()).mediaRetentionDays, isNull, reason: 'serveur antérieur');
    });

    test('appliquée à la politique d’expiration, oubliée à la déconnexion', () async {
      // Le 410 annonce le plafond du serveur (un abonné garde 365 jours)…
      MediaExpiryPolicy.resetForTests(retentionDays: 365);
      final s = EntitlementService(api: TalkyApiClient());
      // … mais ce compte, standard, s'arrête à 30.
      await s.applyFromProfile({
        'entitlements': {..._payload(), 'mediaRetentionDays': 30},
      });
      expect(MediaExpiryPolicy.retentionDays, 30);

      const url = 'https://www.alanya237.com/uploads/media/2026-08-01/images/a.jpg';
      expect(MediaExpiryPolicy.isExpired(url, now: DateTime.utc(2026, 9, 15)), isTrue);

      await s.clear();
      expect(MediaExpiryPolicy.retentionDays, 365, reason: 'retour à la durée apprise');
      expect(MediaExpiryPolicy.isExpired(url, now: DateTime.utc(2026, 9, 15)), isFalse);
    });

    test('rechargée depuis le cache au démarrage', () async {
      final a = EntitlementService(api: TalkyApiClient());
      await a.applyFromProfile({
        'entitlements': {..._payload(), 'mediaRetentionDays': 365},
      });
      MediaExpiryPolicy.resetForTests();

      final b = EntitlementService(api: TalkyApiClient());
      await b.loadFromCache();
      expect(MediaExpiryPolicy.retentionDays, 365);
    });
  });

  // Plafonds d'envoi de CE compte : l'app les applique dès le choix du fichier.
  group('plafonds d’envoi', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      MediaUploadLimits.apply();
    });

    Map<String, dynamic> withLimits(int bytes, int album, String tier) => {
          ..._payload(),
          'limits': {'maxUploadBytes': bytes, 'maxAlbumItems': album, 'tier': tier},
        };

    test('lus dans les droits, gardés par le cache', () {
      final e = Entitlements.fromJson(withLimits(200 * _mo, 100, 'paid'));
      expect(e.maxUploadBytes, 200 * _mo);
      expect(e.maxAlbumItems, 100);
      final relu = Entitlements.fromJson(e.toJson());
      expect(relu.maxUploadBytes, 200 * _mo);
      expect(relu.maxAlbumItems, 100);
      expect(Entitlements.fromJson(_payload()).maxUploadBytes, isNull, reason: 'serveur antérieur');
    });

    test('sans rien d’annoncé : palier standard', () {
      expect(MediaUploadLimits.maxBytes, kMaxMediaUploadBytes);
      expect(MediaUploadLimits.maxMegabytes, 100);
      expect(MediaUploadLimits.maxAlbumItems, kMaxAlbumItems);
    });

    test('appliqués à l’app, oubliés à la déconnexion', () async {
      final s = EntitlementService(api: TalkyApiClient());
      await s.applyFromProfile({'entitlements': withLimits(200 * _mo, 100, 'paid')});
      expect(MediaUploadLimits.maxBytes, 200 * _mo);
      expect(MediaUploadLimits.maxMegabytes, 200);
      expect(MediaUploadLimits.maxAlbumItems, 100);

      await s.clear();
      expect(MediaUploadLimits.maxBytes, kMaxMediaUploadBytes,
          reason: 'le compte suivant ne garde pas les plafonds de l’abonné');
      expect(MediaUploadLimits.maxAlbumItems, kMaxAlbumItems);
    });

    test('serveur antérieur, sans plafonds : palier standard', () async {
      final s = EntitlementService(api: TalkyApiClient());
      await s.applyFromProfile({'entitlements': _payload()});
      expect(MediaUploadLimits.maxBytes, kMaxMediaUploadBytes);
      expect(MediaUploadLimits.maxAlbumItems, kMaxAlbumItems);
    });

    test('rechargés depuis le cache au démarrage', () async {
      final a = EntitlementService(api: TalkyApiClient());
      await a.applyFromProfile({'entitlements': withLimits(200 * _mo, 100, 'paid')});
      MediaUploadLimits.apply();

      final b = EntitlementService(api: TalkyApiClient());
      await b.loadFromCache();
      expect(MediaUploadLimits.maxBytes, 200 * _mo);
      expect(MediaUploadLimits.maxAlbumItems, 100);
    });
  });
}
