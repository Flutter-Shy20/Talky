import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/billing/entitlements.dart';
import 'package:talky_flutter/core/services/billing/verification_models.dart';

VerificationState _state({
  Map<String, dynamic>? request,
  int status = 0,
  bool available = true,
}) =>
    VerificationState.fromJson({
      'available': available,
      'currentName': 'Marie Kouassi',
      'verification': {'status': status, 'until': null},
      'request': request,
      'documents': [
        {'id': 1, 'docType': 1, 'purged': false},
        {'id': 2, 'docType': 4, 'purged': true},
      ],
    });

void main() {
  group('VerificationState', () {
    test('lit le dossier, les pièces et la coche', () {
      final s = _state(
        status: 1,
        request: {
          'id': 7,
          'status': 'document_requested',
          'claimedName': 'Marie Kouassi',
          'reason': 'Le verso est illisible',
          'createdAt': '2026-09-22T19:40:00.000Z',
        },
      );
      expect(s.available, isTrue);
      expect(s.request!.status, VerificationRequestStatus.documentRequested);
      expect(s.request!.reason, 'Le verso est illisible');
      expect(s.request!.createdAt, DateTime.utc(2026, 9, 22, 19, 40));
      expect(s.documents.map((d) => d.docType), [
        VerificationDocType.identity,
        VerificationDocType.selfie,
      ]);
      expect(s.documents.last.purged, isTrue);
    });

    test('un seul dossier ouvert à la fois', () {
      expect(_state().canSubmit, isTrue, reason: 'jamais demandé');
      expect(_state(request: {'id': 1, 'status': 'pending'}).canSubmit,
          isFalse);
      expect(
          _state(request: {'id': 1, 'status': 'document_requested'}).canSubmit,
          isFalse);
      expect(_state(request: {'id': 1, 'status': 'refused'}).canSubmit, isTrue);
      expect(_state(request: {'id': 1, 'status': 'revoked'}).canSubmit, isTrue);
    });

    test('approuvé : nouveau dépôt seulement après un changement de nom', () {
      expect(
          _state(status: 2, request: {'id': 1, 'status': 'approved'}).canSubmit,
          isFalse);
      expect(
          _state(status: 1, request: {
            'id': 1,
            'status': 'approved',
            'nameChanged': true,
          }).canSubmit,
          isTrue);
    });

    test('coche vérifiée, ou en pause faute d\'abonnement', () {
      expect(_state(status: 2).isVerified, isTrue);
      expect(_state(status: 5).isPaused, isTrue);
      expect(_state(status: 5).isVerified, isFalse);
    });

    test('réponse vide : rien d\'ouvert, dépôt possible', () {
      final s = VerificationState.fromJson(const {});
      expect(s.available, isFalse);
      expect(s.request, isNull);
      expect(s.canSubmit, isTrue);
    });
  });

  group('Droits : la coche voyage avec eux', () {
    test('lue, et gardée en cache', () {
      final e = Entitlements.fromJson({
        'phase': 'paid',
        'features': {},
        'verification': {'status': 2, 'until': '2027-10-10T00:00:00.000Z'},
      });
      expect(e.isVerified, isTrue);
      expect(e.verifiedUntil, DateTime.utc(2027, 10, 10));
      final again = Entitlements.fromJson(e.toJson());
      expect(again.verificationStatus, 2);
    });

    test('serveur antérieur : inconnue', () {
      final e = Entitlements.fromJson({'phase': 'free', 'features': {}});
      expect(e.verificationStatus, isNull);
      expect(e.isVerified, isFalse);
    });
  });
}
