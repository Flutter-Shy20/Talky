// Le natif peut enregistrer un décrochage pendant que Flutter n'écoute pas.
//
// Au retour au premier plan, l'application reprenait l'entrant : elle
// revendiquait la présentation et relançait sa sonnerie sur un appel que
// l'utilisateur venait de décrocher.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_terminal_guards.dart';

bool decide({
  bool entrant = true,
  bool autoReponse = false,
  String? presente = 'c-7',
  String? actif = 'c-7',
  bool accepte = true,
}) =>
    shouldAdoptNativeAccept(
      statusIsIncoming: entrant,
      autoAnsweringFromPush: autoReponse,
      presentationId: presente,
      activeCallId: actif,
      activeAccepted: accepte,
    );

void main() {
  test('entrée acceptée pour l\'appel présenté → on adopte', () {
    expect(decide(), isTrue);
  });

  test('entrée non acceptée → rien à adopter', () {
    expect(decide(accepte: false), isFalse);
  });

  test('entrée résiduelle d\'un AUTRE appel → surtout pas', () {
    // Sinon on décrocherait l'appel en cours sur la foi d'un débris.
    expect(decide(actif: 'c-9'), isFalse);
  });

  test('plus d\'entrant, ou auto-réponse déjà en cours → rien à faire', () {
    expect(decide(entrant: false), isFalse);
    expect(decide(autoReponse: true), isFalse);
  });

  test('un identifiant manquant ne désigne rien', () {
    expect(decide(presente: null), isFalse);
    expect(decide(actif: '  '), isFalse);
  });
}
