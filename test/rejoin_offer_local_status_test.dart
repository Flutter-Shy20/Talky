// La restauration après mort de processus ne marchait que pour l'appelant.
//
// Seul lui persiste un instantané. L'appelé redémarré se retrouve en
// « entrant » avec l'auto-réponse armée ; l'offre de rejointe de son
// correspondant arrivait alors et était jetée. Écran figé trente secondes
// puis « Échec », et le correspondant attendait quarante-cinq secondes.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_terminal_guards.dart';

bool accepte(
  String statut, {
  bool restaure = false,
  bool memePair = true,
  bool autoReponse = false,
}) =>
    acceptsRejoinOfferForLocalStatus(
      callStatusName: statut,
      isRestoringOutgoing: restaure,
      peerMatchesRemote: memePair,
      awaitingAutoAnswer: autoReponse,
    );

void main() {
  test('un appel vivant accepte toujours une reprise', () {
    expect(accepte('connected'), isTrue);
    expect(accepte('reconnecting'), isTrue);
  });

  test('une restauration en cours accepte, quel que soit le statut', () {
    expect(accepte('outgoing', restaure: true), isTrue);
    expect(accepte('idle', restaure: true), isTrue);
  });

  test('en connexion, seulement pour le même correspondant', () {
    expect(accepte('connecting'), isTrue);
    expect(accepte('connecting', memePair: false), isFalse);
  });

  test('appelé restauré : entrant avec auto-réponse armée', () {
    // C'est le cas qui ne marchait pas.
    expect(accepte('incoming', autoReponse: true), isTrue);
  });

  test('un entrant qui sonne vraiment ne reprend rien', () {
    // Sans auto-réponse, personne n'a décroché : il n'y a rien à reprendre.
    expect(accepte('incoming'), isFalse);
    expect(accepte('incoming', autoReponse: true, memePair: false), isFalse);
  });

  test('les états sans appel refusent', () {
    expect(accepte('idle'), isFalse);
    expect(accepte('ended'), isFalse);
    expect(accepte('outgoing'), isFalse);
  });
}
