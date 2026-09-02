// Rendre une session qu'on n'a jamais prise démontait celle du voisin.
//
// `acquire` refuse proprement un conflit sans compter — mais `release`
// décrémentait aveuglément. La session refusée faisait donc tomber le compteur
// à zéro en se retirant : service au premier plan arrêté, focus audio rendu,
// entrée CallKit fermée, sur un appel ou une réunion toujours en cours.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call_session_guard.dart';

void main() {
  test('le tenant peut rendre sa session', () {
    expect(
      shouldReleaseSession(refCount: 1, heldBy: 'appel-7', releasedBy: 'appel-7'),
      isTrue,
    );
  });

  test('un autre ne peut pas rendre celle du tenant', () {
    // Réunion tenant la session, appel refusé qui se termine : c'est le cas.
    expect(
      shouldReleaseSession(
        refCount: 1,
        heldBy: 'meeting_12',
        releasedBy: 'appel-7',
      ),
      isFalse,
    );
  });

  test('personne ne tient : rien à rendre', () {
    expect(
      shouldReleaseSession(refCount: 0, heldBy: null, releasedBy: 'appel-7'),
      isFalse,
    );
  });

  test('un appelant sans identité garde l\'ancien comportement', () {
    // On ne peut pas lui refuser ce qu'on ne sait pas attribuer.
    expect(
      shouldReleaseSession(refCount: 1, heldBy: 'appel-7', releasedBy: null),
      isTrue,
    );
    expect(
      shouldReleaseSession(refCount: 1, heldBy: 'appel-7', releasedBy: '  '),
      isTrue,
    );
  });

  test('une session tenue sans identité connue se rend à qui la demande', () {
    expect(
      shouldReleaseSession(refCount: 1, heldBy: null, releasedBy: 'appel-7'),
      isTrue,
    );
  });
}
