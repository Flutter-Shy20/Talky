import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/widgets/common/account_badge.dart';

void main() {
  group('resolveAccountBadge', () {
    test('personnel sans vérif → none', () {
      expect(resolveAccountBadge(0, 0), AccountBadge.none);
    });
    test('personnel vérifié → cocheVerifiee', () {
      expect(resolveAccountBadge(0, 2), AccountBadge.cocheVerifiee);
    });
    test('personnel en attente, refusé, révoqué ou expiré → none', () {
      for (final status in [1, 3, 4, 5]) {
        expect(resolveAccountBadge(0, status), AccountBadge.none,
            reason: 'statut $status');
      }
    });
    test('business non vérifié → panierDeclare', () {
      expect(resolveAccountBadge(1, 0), AccountBadge.panierDeclare);
    });
    test('business vérifié → panierVerifie', () {
      expect(resolveAccountBadge(1, 2), AccountBadge.panierVerifie);
    });
    test('officiel ignore verification_status → officiel', () {
      expect(resolveAccountBadge(2, 0), AccountBadge.officiel);
      expect(resolveAccountBadge(2, 2), AccountBadge.officiel);
    });
  });

  testWidgets('la coche est dessinée à la taille demandée', (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: VerifiedSeal(size: 18)),
    ));
    final box = tester.getSize(find.byType(VerifiedSeal));
    expect(box, const Size(18, 18));
  });
}
