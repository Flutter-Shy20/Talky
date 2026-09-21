// Le plugin CallKit réaffiche l'entrant dans des cas ordinaires — la bascule
// vers CallKit au retour au premier plan en était un. L'aperçu revenait vers
// `handleIncomingCallKitPreview`, qui le prenait pour un appel étranger et le
// fermait : l'appel était marqué terminé, un refus partait au serveur, et le
// décrochage en cours était perdu des deux côtés.

import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_terminal_guards.dart';

void main() {
  group('un aperçu CallKit de l\'appel courant', () {
    test('l\'identifiant du serveur suffit à le reconnaître', () {
      expect(
        previewTargetsCurrentCall(
          previewCallId: '2332',
          callStatusName: 'connecting',
          currentCallId: '2332',
        ),
        isTrue,
        reason: 'c\'est l\'appel qu\'on est en train de décrocher : le fermer '
            'le refusait au correspondant',
      );
    });

    test('l\'identifiant sous lequel CallKit a été ouvert compte aussi', () {
      expect(
        previewTargetsCurrentCall(
          previewCallId: '1789508940989',
          callStatusName: 'connected',
          currentCallId: '2332',
          callKitCallId: '1789508940989',
        ),
        isTrue,
        reason: 'un appel sortant porte deux identifiants, et le natif ne '
            'connaît que celui-là',
      );
    });

    test('le salon de groupe et la session à trois comptent', () {
      expect(
        previewTargetsCurrentCall(
          previewCallId: 'group_12_99',
          callStatusName: 'connected',
          groupRoomId: 'group_12_99',
        ),
        isTrue,
      );
      expect(
        previewTargetsCurrentCall(
          previewCallId: 'conf_77_1',
          callStatusName: 'connected',
          confSessionId: 'conf_77_1',
        ),
        isTrue,
      );
    });

    test('un autre appel reste un autre appel', () {
      expect(
        previewTargetsCurrentCall(
          previewCallId: '2339',
          callStatusName: 'connected',
          currentCallId: '2332',
          callKitCallId: '1789508940989',
        ),
        isFalse,
        reason: 'le nettoyage habituel doit continuer de s\'appliquer aux '
            'appels étrangers',
      );
    });

    test('hors appel, il n\'y a rien à protéger', () {
      for (final statut in ['idle', 'ended']) {
        expect(
          previewTargetsCurrentCall(
            previewCallId: '2332',
            callStatusName: statut,
            currentCallId: '2332',
          ),
          isFalse,
          reason: statut,
        );
      }
    });

    test('un aperçu sans identifiant ne désigne rien', () {
      for (final vide in [null, '', '   ']) {
        expect(
          previewTargetsCurrentCall(
            previewCallId: vide,
            callStatusName: 'connecting',
            currentCallId: '2332',
          ),
          isFalse,
          reason: 'aperçu=${vide ?? "null"}',
        );
      }
    });

    test('un identifiant courant vide ne fait pas correspondance', () {
      expect(
        previewTargetsCurrentCall(
          previewCallId: '2332',
          callStatusName: 'connecting',
          currentCallId: '',
          callKitCallId: null,
        ),
        isFalse,
      );
    });
  });
}
