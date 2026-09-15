import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/meeting/meeting_join_affordance.dart';

void main() {
  final debut = DateTime(2026, 9, 3, 14, 0);
  const duree = 60;

  MeetingPhase phase(DateTime maintenant, {bool isEnd = false}) => phaseReunion(
        isEnd: isEnd,
        debut: debut,
        dureeMinutes: duree,
        maintenant: maintenant,
      );

  group('phaseReunion', () {
    test('terminée par l’organisateur, quelle que soit l’heure', () {
      expect(phase(debut.subtract(const Duration(days: 1)), isEnd: true),
          MeetingPhase.terminee);
      expect(phase(debut.add(const Duration(minutes: 10)), isEnd: true),
          MeetingPhase.terminee);
    });

    test('programmée bien à l’avance', () {
      expect(phase(debut.subtract(const Duration(hours: 2))),
          MeetingPhase.programmee);
    });

    test('bientôt : dans le quart d’heure', () {
      expect(phase(debut.subtract(const Duration(minutes: 15))),
          MeetingPhase.bientot);
      expect(phase(debut.subtract(const Duration(minutes: 1))),
          MeetingPhase.bientot);
    });

    test('en cours entre le début et la fin', () {
      expect(phase(debut), MeetingPhase.enCours);
      expect(phase(debut.add(const Duration(minutes: 59))),
          MeetingPhase.enCours);
    });

    test('échue à la seconde exacte de la fin', () {
      // Borne haute exclue, comme la garde d'entrée côté serveur.
      expect(phase(debut.add(const Duration(minutes: duree))),
          MeetingPhase.echue);
    });

    test('échue longtemps après', () {
      expect(phase(debut.add(const Duration(days: 21))), MeetingPhase.echue);
    });
  });

  group('peutRejoindre', () {
    test('le bouton disparaît sur une réunion terminée', () {
      // Le défaut S2 : il survivait à la fin de la réunion.
      expect(peutRejoindre(MeetingPhase.terminee), isFalse);
    });

    test('et sur une réunion dont l’heure est passée', () {
      expect(peutRejoindre(MeetingPhase.echue), isFalse);
    });

    test('il reste sur tout le reste, comme avant', () {
      // Périmètre inchangé : rejoindre une réunion programmée pour la semaine
      // prochaine restait possible, et le reste possible.
      expect(peutRejoindre(MeetingPhase.enCours), isTrue);
      expect(peutRejoindre(MeetingPhase.bientot), isTrue);
      expect(peutRejoindre(MeetingPhase.programmee), isTrue);
    });
  });

  group('afficheCommandesCamera', () {
    test('réunion vidéo : les commandes caméra ont un sens', () {
      expect(afficheCommandesCamera(0), isTrue);
    });

    test('réunion audio seule : deux boutons qui ne répondaient pas', () {
      // `_initLocalStream` force isVideoOff et il n'existe aucune piste vidéo :
      // `toggleVideo` sortait sans rien faire.
      expect(afficheCommandesCamera(1), isFalse);
    });

    test('type inconnu ou absent : on n’offre pas une commande incertaine', () {
      expect(afficheCommandesCamera(null), isFalse);
      expect(afficheCommandesCamera(9), isFalse);
    });
  });
}
