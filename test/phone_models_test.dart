import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/billing/billing_models.dart';
import 'package:talky_flutter/core/services/billing/phone_models.dart';

void main() {
  group('Offre du numéro choisi', () {
    test('lue telle que la rend le serveur (alanyaPhonePurchase.offer)', () {
      final offer = PhoneOffer.fromJson({
        'purchasable': true,
        'price': 1000,
        'currency': 'XAF',
        'holdMinutes': 15,
        'provider': {
          'name': 'simulated',
          'channels': ['orange_money', 'mtn_momo'],
          'simulated': true,
        },
        'currentPhone': '00482917',
        'order': {
          'id': 12,
          'phone': '11223344',
          'status': 'paying',
          'heldUntil': '2026-09-26T14:15:00.000Z',
          'paymentId': 40,
        },
        'credit': false,
      });
      expect(offer.purchasable, isTrue);
      expect(offer.price, 1000);
      expect(offer.provider?.simulated, isTrue);
      expect(offer.provider?.channels, [PaymentChannel.orangeMoney, PaymentChannel.mtnMomo]);
      expect(offer.currentPhone, '00482917');
      expect(offer.order?.status, PhoneOrderStatus.paying);
      expect(offer.order?.paymentId, 40);
      expect(offer.order?.heldUntil, DateTime.utc(2026, 9, 26, 14, 15));
      expect(offer.credit, isFalse);
    });

    test('hors de portée : rien à proposer', () {
      final offer = PhoneOffer.fromJson({'purchasable': false, 'order': null});
      expect(offer.purchasable, isFalse);
      expect(offer.order, isNull);
      expect(offer.provider, isNull);
    });
  });

  group('Disponibilité', () {
    test('chaque raison du serveur a son nom', () {
      for (final (wire, refusal) in [
        ('same', PhoneRefusal.same),
        ('taken', PhoneRefusal.taken),
        ('set_aside', PhoneRefusal.setAside),
        ('held', PhoneRefusal.held),
        ('quarantine', PhoneRefusal.quarantine),
      ]) {
        final a = PhoneAvailability.fromJson(
            {'phone': '12345678', 'available': false, 'reason': wire});
        expect(a.reason, refusal, reason: wire);
        expect(a.available, isFalse);
      }
    });

    test('disponible : aucune raison', () {
      final a = PhoneAvailability.fromJson(
          {'phone': '12345678', 'available': true, 'reason': null});
      expect(a.available, isTrue);
      expect(a.reason, isNull);
    });
  });

  group('Mise de côté', () {
    test('une commande retenue', () {
      final r = PhoneHoldResult.fromJson({
        'order': {
          'id': 3,
          'phone': '12345678',
          'status': 'held',
          'heldUntil': '2026-09-26T14:15:00.000Z',
          'paymentId': null,
        },
      });
      expect(r.applied, isFalse);
      expect(r.order?.status, PhoneOrderStatus.held);
      expect(r.order?.paymentId, isNull);
    });

    test('un crédit utilisé : le numéro est déjà posé', () {
      final r = PhoneHoldResult.fromJson(
          {'order': null, 'applied': true, 'credit': false, 'phone': '12345678'});
      expect(r.order, isNull);
      expect(r.applied, isTrue);
      expect(r.phone, '12345678');
    });
  });

  test('un paiement de numéro se distingue d\'un abonnement', () {
    expect(PlusPayment.fromJson({'id': 1, 'status': 'succeeded', 'product': 'phone'}).isPhone, isTrue);
    expect(PlusPayment.fromJson({'id': 2, 'status': 'succeeded', 'plan': 'plus_annuel'}).isPhone, isFalse,
        reason: 'un serveur plus ancien n\'envoie pas product');
  });
}
