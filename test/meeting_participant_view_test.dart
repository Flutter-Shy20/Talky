import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/meeting/meeting_participant_view.dart';

void main() {
  group('badgeParticipant', () {
    test('invité qui n’a jamais rejoint : en attente', () {
      expect(
        badgeParticipant(status: 0, estOrganisateur: false),
        MeetingParticipantBadge.enAttente,
      );
    });

    test('invité qui a rejoint : a rejoint', () {
      expect(
        badgeParticipant(status: 1, estOrganisateur: false),
        MeetingParticipantBadge.aRejoint,
      );
    });

    test('l’organisateur est toujours « a rejoint », même à status 0', () {
      // Filet pour une réunion créée avant la migration de rattrapage — son
      // propre détail ne doit jamais l'annoncer « en attente ».
      expect(
        badgeParticipant(status: 0, estOrganisateur: true),
        MeetingParticipantBadge.aRejoint,
      );
    });

    test('un statut mort (2) ne prétend jamais « a rejoint »', () {
      expect(
        badgeParticipant(status: 2, estOrganisateur: false),
        MeetingParticipantBadge.enAttente,
      );
    });
  });
}
