import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/billing/billing_models.dart';
import 'package:talky_flutter/core/services/billing/entitlements.dart';

/// Réponse de `GET /billing/offer` telle que la rend le serveur
/// (billingController.getOffer), avec les deux plans de la migration 080.
Map<String, dynamic> _offerJson() => {
      'phase': 'paid',
      'graceUntil': null,
      'purchasable': true,
      'plans': [
        {
          'code': 'plus_mensuel',
          'name': {'fr': 'Mensuel', 'en': 'Monthly', 'zh': ''},
          'durationMonths': 1,
          'price': 250,
          'currency': 'XAF',
          'featured': false,
          'features': ['translation'],
        },
        {
          'code': 'plus_annuel',
          'name': {'fr': 'Annuel', 'en': 'Yearly'},
          'durationMonths': 12,
          'price': 2000,
          'currency': 'XAF',
          'featured': true,
          'features': ['translation', 'backup'],
        },
      ],
      'features': [
        {
          'code': 'translation',
          'name': {'fr': 'Traduction'},
          'description': {'fr': 'des messages'},
        },
        {'code': 'pas_encore_livree', 'name': {'fr': 'X'}},
      ],
      'provider': {
        'name': 'simulated',
        'channels': ['orange_money', 'mtn_momo', 'wave'],
        'simulated': true,
      },
      'entitlements': {
        'phase': 'paid',
        'features': {'translation': false},
      },
    };

void main() {
  group('PlusOffer', () {
    final offer = PlusOffer.fromJson(_offerJson());

    test('lit les plans, le fournisseur et les droits', () {
      expect(offer.plans.map((p) => p.code), ['plus_mensuel', 'plus_annuel']);
      expect(offer.purchasable, isTrue);
      expect(offer.provider!.simulated, isTrue);
      expect(
        offer.provider!.channels,
        [PaymentChannel.orangeMoney, PaymentChannel.mtnMomo],
        reason: 'un moyen inconnu de l\'app est ignoré, pas planté',
      );
      expect(offer.entitlements.known, isTrue);
      expect(offer.entitlements.has(PlusFeature.translation), isFalse);
    });

    test('l\'annuel est présélectionné, le mensuel sert de référence', () {
      expect(offer.defaultPlan!.code, 'plus_annuel');
      expect(offer.reference!.code, 'plus_mensuel');
      expect(offer.planByCode('plus_mensuel')!.price, 250);
      expect(offer.planByCode('inconnu'), isNull);
    });

    test('l\'argument de prix se calcule comme dans l\'administration', () {
      final annual = offer.planByCode('plus_annuel')!;
      expect(annual.monthlyEquivalent, 167, reason: '2 000 / 12, arrondi');
      expect(annual.monthsOffered(offer.reference), 4,
          reason: '12 × 250 − 2 000 = 1 000, soit 4 mois');
      expect(offer.reference!.monthsOffered(offer.reference), 0);
      expect(offer.lowestMonthly, 167);
    });

    test('le nom retombe sur le français quand la langue manque', () {
      final monthly = offer.planByCode('plus_mensuel')!;
      expect(monthly.nameFor('en'), 'Monthly');
      expect(monthly.nameFor('zh'), 'Mensuel', reason: 'traduction vide');
    });

    test('une fonctionnalité inconnue de l\'app reste affichable', () {
      expect(offer.features.first.feature, PlusFeature.translation);
      expect(offer.features.first.descriptionFor('en'), 'des messages');
      expect(offer.features.last.feature, isNull);
    });

    test('réponse vide : rien à vendre, tout permis', () {
      final empty = PlusOffer.fromJson(const {});
      expect(empty.purchasable, isFalse);
      expect(empty.defaultPlan, isNull);
      expect(empty.lowestMonthly, isNull);
      expect(empty.entitlements.known, isFalse);
    });
  });

  group('normalizeMsisdn — même règle que le serveur', () {
    test('numéro local, avec indicatif, avec espaces ou 00', () {
      expect(normalizeMsisdn('699123400'), '237699123400');
      expect(normalizeMsisdn('+237 6 99 12 34 00'), '237699123400');
      expect(normalizeMsisdn('00237 699-12-34-00'), '237699123400');
      expect(normalizeMsisdn('(237) 699.12.34.00'), '237699123400');
    });

    test('refuse ce qui n\'est pas un mobile camerounais valide', () {
      expect(normalizeMsisdn('237599123400'), isNull,
          reason: 'un mobile camerounais commence par 6');
      expect(normalizeMsisdn('69912340'), isNull, reason: 'huit chiffres');
      expect(normalizeMsisdn('12345'), isNull);
      expect(normalizeMsisdn('abc'), isNull);
    });

    test('laisse passer un numéro international complet', () {
      expect(normalizeMsisdn('+225 07 01 02 03 04'), '2250701020304');
    });
  });

  group('Paiements', () {
    test('seuls les états terminaux concluent l\'attente', () {
      expect(PaymentStatus.fromWire('succeeded')!.isFinal, isTrue);
      expect(PaymentStatus.fromWire('failed')!.isFinal, isTrue);
      expect(PaymentStatus.fromWire('expired')!.isFinal, isTrue);
      expect(PaymentStatus.fromWire('pending')!.isFinal, isFalse);
      expect(PaymentStatus.fromWire('created')!.isFinal, isFalse);
      expect(PaymentStatus.fromWire('inconnu'), isNull);
    });

    test('statut de paiement', () {
      final p = PlusPayment.fromJson({
        'id': 42,
        'status': 'failed',
        'plan': 'plus_annuel',
        'amount': 2000,
        'currency': 'XAF',
        'channel': 'mtn_momo',
        'failureCode': 'INSUFFICIENT_FUNDS',
        'createdAt': '2026-10-01T08:00:00.000Z',
        'confirmedAt': null,
      });
      expect(p.id, 42);
      expect(p.status, PaymentStatus.failed);
      expect(p.channel, PaymentChannel.mtnMomo);
      expect(p.failureCode, 'INSUFFICIENT_FUNDS');
      expect(p.createdAt, DateTime.utc(2026, 10, 1, 8));
      expect(p.confirmedAt, isNull);
    });

    test('la demande de paiement n\'est jamais un paiement fait', () {
      final r = CheckoutResult.fromJson({
        'paymentId': 7,
        'status': 'pending',
        'amount': 250,
        'currency': 'XAF',
      });
      expect(r.paymentId, 7);
      expect(r.status, PaymentStatus.pending);
    });

    test('historique : périodes et paiements', () {
      final h = PlusHistory.fromJson({
        'periods': [
          {
            'plan': 'plus_annuel',
            'startsAt': '2026-10-10T00:00:00.000Z',
            'endsAt': '2027-10-10T00:00:00.000Z',
            'source': 2,
          },
        ],
        'payments': [
          {'id': 1, 'status': 'succeeded', 'amount': 2000},
        ],
      });
      expect(h.periods.single.source, 2);
      expect(h.periods.single.endsAt, DateTime.utc(2027, 10, 10));
      expect(h.payments.single.status, PaymentStatus.succeeded);
    });
  });

  group('Droits', () {
    test('le code serveur d\'un refus désigne la fonctionnalité', () {
      expect(PlusFeature.fromCode('backup'), PlusFeature.backup);
      expect(PlusFeature.fromCode('trusted_trips'), PlusFeature.trustedTrips);
      expect(PlusFeature.fromCode('inconnue'), isNull);
      expect(PlusFeature.fromCode(null), isNull);
    });

    test('la fin d\'abonnement survit au cache', () {
      final e = Entitlements.fromJson({
        'phase': 'paid',
        'features': {},
        'lapsedAt': '2026-11-17T00:00:00.000Z',
      });
      final again = Entitlements.fromJson(e.toJson());
      expect(again.lapsedAt, DateTime.utc(2026, 11, 17));
    });
  });
}
