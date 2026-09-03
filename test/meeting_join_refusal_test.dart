import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/meeting/meeting_join_refusal.dart';

void main() {
  group('refusPourErreur', () {
    test('un appel en cours est nommé, pas affiché brut', () {
      // Sans ce classement, le lobby montrait « Bad state: SESSION_BUSY ».
      expect(
        refusPourErreur(StateError('SESSION_BUSY')),
        MeetingJoinRefusal.sessionOccupee,
      );
    });

    test('les trois refus du serveur sont reconnus', () {
      expect(refusPourErreur(StateError('MEETING_ENDED')),
          MeetingJoinRefusal.reunionTerminee);
      expect(refusPourErreur(StateError('MEETING_EXPIRED')),
          MeetingJoinRefusal.reunionEchue);
      expect(refusPourErreur(StateError('NOT_A_PARTICIPANT')),
          MeetingJoinRefusal.nonInvite);
    });

    test('une erreur inconnue garde son message d’origine', () {
      // Une exception HTTP porte déjà une phrase du serveur, plus informative
      // que n'importe quelle reformulation.
      expect(
        refusPourErreur(Exception('Réunion introuvable')),
        MeetingJoinRefusal.autre,
      );
      expect(refusPourErreur(null), MeetingJoinRefusal.autre);
    });

    test('l’ordre de test ne confond pas deux codes proches', () {
      // MEETING_ENDED et MEETING_EXPIRED partagent un préfixe : le test doit
      // porter sur le code entier, pas sur « MEETING_ ».
      expect(refusPourErreur(StateError('MEETING_EXPIRED')),
          isNot(MeetingJoinRefusal.reunionTerminee));
    });
  });
}
