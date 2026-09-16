// Le bouton de sortie audio ne faisait rien : depuis que chaque appel est
// déclaré à Telecom, c'est Android qui arbitre la route, et nos demandes
// passaient par `AudioManager.setSpeakerphoneOn`, qu'il ignore. Second défaut,
// indépendant : « enlever le haut-parleur » signifie, côté flutter_webrtc,
// « prendre le premier appareil disponible parmi Bluetooth, filaire, écouteur »
// — avec un casque appairé, l'écouteur était donc inatteignable.

import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_audio_routes.dart';

void main() {
  group('chaque sortie se demande par son nom', () {
    test('les quatre identifiants attendus par flutter_webrtc', () {
      expect(webrtcDeviceId(CallAudioRoute.earpiece), 'earpiece');
      expect(webrtcDeviceId(CallAudioRoute.speaker), 'speaker');
      expect(webrtcDeviceId(CallAudioRoute.wired), 'wired-headset');
      expect(webrtcDeviceId(CallAudioRoute.bluetooth), 'bluetooth');
    });

    test('l\'écouteur ne se confond plus avec le filaire', () {
      expect(
        webrtcDeviceId(CallAudioRoute.earpiece),
        isNot(webrtcDeviceId(CallAudioRoute.wired)),
        reason: 'les deux passaient par le même appel booléen, qui rendait la '
            'main au premier appareil branché',
      );
    });
  });

  group('aller-retour avec Telecom', () {
    test('chaque sortie se nomme et se relit', () {
      for (final route in CallAudioRoute.values) {
        expect(
          routeFromTelecomName(telecomRouteName(route)),
          route,
          reason: route.name,
        );
      }
    });

    test('un nom inconnu ne désigne rien', () {
      for (final nom in [null, '', 'inconnu', 'ROUTE_SPEAKER']) {
        expect(routeFromTelecomName(nom), isNull, reason: '$nom');
      }
    });
  });

  group('sorties disponibles d\'après le masque Telecom', () {
    test('écouteur et haut-parleur seuls', () {
      expect(
        routesFromSupportedMask(1 | 8),
        [CallAudioRoute.earpiece, CallAudioRoute.speaker],
      );
    });

    test('avec un casque Bluetooth', () {
      expect(
        routesFromSupportedMask(1 | 8 | 2),
        [
          CallAudioRoute.earpiece,
          CallAudioRoute.speaker,
          CallAudioRoute.bluetooth,
        ],
        reason: 'le Bluetooth doit être atteignable, mais après l\'écouteur : '
            'l\'ordre du bouton ne change pas',
      );
    });

    test('les quatre, dans l\'ordre d\'affichage', () {
      expect(
        routesFromSupportedMask(1 | 2 | 4 | 8),
        [
          CallAudioRoute.earpiece,
          CallAudioRoute.speaker,
          CallAudioRoute.wired,
          CallAudioRoute.bluetooth,
        ],
      );
    });

    test('un masque vide n\'annonce rien', () {
      expect(routesFromSupportedMask(0), isEmpty);
    });
  });

  group('la sortie affichée est celle qui s\'applique', () {
    test('le natif fait autorité', () {
      expect(
        resolveAppliedRoute(
          requested: CallAudioRoute.earpiece,
          reportedName: 'bluetooth',
        ),
        CallAudioRoute.bluetooth,
        reason: 'Telecom peut refuser la demande : afficher l\'écouteur alors '
            'que le son sort du casque, c\'est mentir à l\'utilisateur',
      );
    });

    test('sans réponse du natif, on montre ce qu\'on a demandé', () {
      for (final absent in [null, '', 'inconnu']) {
        expect(
          resolveAppliedRoute(
            requested: CallAudioRoute.speaker,
            reportedName: absent,
          ),
          CallAudioRoute.speaker,
          reason: '$absent',
        );
      }
    });
  });
}
