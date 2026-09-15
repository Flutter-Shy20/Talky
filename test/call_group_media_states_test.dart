// Les états micro/caméra de groupe reçus avant leur auteur.
//
// Le handler ne les appliquait que si l'auteur était déjà au roster, et les
// jetait sinon. Or l'arrivant dans un appel de groupe n'avait, jusqu'au
// correctif serveur de `group_participants`, que lui-même à son roster : les
// coupures de micro des autres tombaient toutes dans ce trou.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_group_media_states.dart';

void main() {
  late PendingGroupMediaStates pending;

  setUp(() => pending = PendingGroupMediaStates());

  test('rien retenu au départ', () {
    expect(pending.isEmpty, isTrue);
    final rien = pending.take('20');
    expect(rien.isMuted, isNull);
    expect(rien.isVideoOn, isNull);
  });

  test('un état retenu est rendu à celui qui le réclame', () {
    pending.recordMuted('20', true);
    expect(pending.isEmpty, isFalse);
    final etat = pending.take('20');
    expect(etat.isMuted, isTrue);
    expect(etat.isVideoOn, isNull, reason: 'la caméra n\'a rien dit');
  });

  test('les deux états cohabitent pour un même participant', () {
    pending.recordMuted('20', true);
    pending.recordVideoOn('20', false);
    final etat = pending.take('20');
    expect(etat.isMuted, isTrue);
    expect(etat.isVideoOn, isFalse);
  });

  test('une bascule plus récente remplace la précédente', () {
    pending.recordMuted('20', true);
    pending.recordMuted('20', false);
    expect(pending.take('20').isMuted, isFalse);
  });

  test('un état pris n\'est plus rendu ensuite', () {
    // Sans le retrait, la deuxième arrivée au roster — après une reprise de
    // salle — réappliquerait un état périmé par-dessus la bascule courante.
    pending.recordMuted('20', true);
    expect(pending.take('20').isMuted, isTrue);
    expect(pending.take('20').isMuted, isNull);
    expect(pending.isEmpty, isTrue);
  });

  test('les participants sont indépendants', () {
    pending.recordMuted('20', true);
    pending.recordMuted('30', false);
    expect(pending.take('20').isMuted, isTrue);
    expect(pending.take('30').isMuted, isFalse);
  });

  test('userIds énumère ceux qui attendent', () {
    pending.recordMuted('20', true);
    pending.recordVideoOn('30', false);
    expect(pending.userIds, {'20', '30'});
  });

  test('un départ efface ce qui l\'attendait', () {
    pending.recordMuted('20', true);
    pending.recordVideoOn('20', false);
    pending.forget('20');
    expect(pending.isEmpty, isTrue);
  });

  test('clear vide tout — fin d\'appel', () {
    pending.recordMuted('20', true);
    pending.recordVideoOn('30', false);
    pending.clear();
    expect(pending.isEmpty, isTrue);
  });

  test('un identifiant vide n\'est pas retenu', () {
    pending.recordMuted('', true);
    pending.recordVideoOn('', false);
    expect(pending.isEmpty, isTrue);
  });

  test('false est une valeur, pas une absence', () {
    // Le piège du `?? false` : « micro rallumé » doit se distinguer de
    // « rien reçu », sinon rallumer son micro n'a aucun effet visible.
    pending.recordMuted('20', false);
    expect(pending.take('20').isMuted, isFalse);
  });
}
