// Rejeu des candidats ICE gardés pendant la sonnerie.
//
// C'est ce rejeu qui évite le silence d'une vingtaine de secondes en début
// d'appel : sans lui, le destinataire décroche sans un seul candidat distant.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_ice_outbox.dart';

OutgoingIceEntry entree(int gen, String nom) =>
    (generation: gen, payload: <String, dynamic>{'candidate': nom});

void main() {
  test('tout part quand le socket répond', () {
    final envoyes = <String>[];
    final r = replayOutgoingIce(
      outbox: [entree(0, 'a'), entree(0, 'b'), entree(0, 'c')],
      generation: 0,
      send: (p) {
        envoyes.add(p['candidate'] as String);
        return true;
      },
    );
    expect(r.sent, 3);
    expect(r.remaining, isEmpty);
    expect(envoyes, ['a', 'b', 'c']);
  });

  test('ce qui n\'a pas pu partir est conservé', () {
    // Le défaut d'origine : la boîte était vidée sans regarder ce qui était
    // réellement parti. Socket tombé une seconde avant le décrochage, et les
    // candidats étaient perdus pour de bon — soit exactement le silence que ce
    // rejeu existe pour éviter.
    final r = replayOutgoingIce(
      outbox: [entree(0, 'a'), entree(0, 'b')],
      generation: 0,
      send: (_) => false,
    );
    expect(r.sent, 0);
    expect(r.remaining.length, 2);
  });

  test('un envoi partiel ne garde que le reste', () {
    var n = 0;
    final r = replayOutgoingIce(
      outbox: [entree(0, 'a'), entree(0, 'b'), entree(0, 'c')],
      generation: 0,
      send: (_) => (n++) == 0, // seul le premier passe
    );
    expect(r.sent, 1);
    expect(
      r.remaining.map((e) => e.payload['candidate']),
      ['b', 'c'],
    );
  });

  test('une génération périmée est oubliée, pas conservée', () {
    // Un ICE restart a renuméroté la négociation : le pair rejetterait ces
    // candidats. Les garder ferait grossir la boîte indéfiniment.
    final r = replayOutgoingIce(
      outbox: [entree(0, 'vieux'), entree(1, 'neuf')],
      generation: 1,
      send: (_) => true,
    );
    expect(r.sent, 1);
    expect(r.remaining, isEmpty);
  });

  test('périmé ET non envoyé : oublié quand même', () {
    final r = replayOutgoingIce(
      outbox: [entree(0, 'vieux')],
      generation: 2,
      send: (_) => false,
    );
    expect(r.sent, 0);
    expect(r.remaining, isEmpty, reason: 'la génération prime sur l\'échec d\'envoi');
  });

  test('une boîte vide ne fait rien', () {
    final r = replayOutgoingIce(
      outbox: const [],
      generation: 0,
      send: (_) => fail('rien ne doit être émis'),
    );
    expect(r.sent, 0);
    expect(r.remaining, isEmpty);
  });

  test('l\'ordre d\'émission est celui de la collecte', () {
    // WebRTC ignore un candidat déjà connu, mais l'ordre reste celui qui donne
    // les meilleures paires en premier.
    final vus = <String>[];
    replayOutgoingIce(
      outbox: [entree(0, 'host'), entree(0, 'srflx'), entree(0, 'relay')],
      generation: 0,
      send: (p) {
        vus.add(p['candidate'] as String);
        return true;
      },
    );
    expect(vus, ['host', 'srflx', 'relay']);
  });
}
