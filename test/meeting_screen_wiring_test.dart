import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Vérifie que les règles pures des réunions sont bien celles qui décident dans
/// l'écran, et pas seulement des fonctions bien testées que personne n'appelle.
///
/// Ce test lit du source, ce qui est inhabituel et se justifie deux fois :
/// `OngoingMeetScreen` n'est pas montable sans `MeetingService`, `AuthProvider`
/// et WebRTC, donc aucun test de widget ne peut l'exercer ; et le projet a déjà
/// le précédent d'une fonction écrite, testée et jamais appelée pendant des
/// mois. Le précédent de lecture de source est `trip_preview_parity_test.dart`.
void main() {
  final ecran =
      File('lib/screens/meetings/ongoing_meet_screen.dart').readAsStringSync();

  group('câblage de l’écran de réunion', () {
    test('la règle de fermeture est consultée, et rien ne pope à côté', () {
      expect(ecran.contains('shouldPopMeetingScreen('), isTrue);
      // Un seul pop de route hors `_minimize` et `_closeOnce`. Les
      // `Navigator.pop(context, …)` de l'AlertDialog ferment la boîte, pas la
      // route, et portent donc un argument.
      final popsNus =
          RegExp(r'Navigator\.pop\(context\);').allMatches(ecran).length;
      expect(popsNus, 0,
          reason: 'les fermetures de route passent toutes par _closeOnce');
    });

    test('la purge du focus est branchée', () {
      expect(ecran.contains('focusEncoreValide('), isTrue);
      expect(ecran.contains('actionRetour('), isTrue);
      expect(ecran.contains('canPop: focusedId == null'), isTrue);
    });

    test('la polarité de la caméra est inversée au bon endroit', () {
      // Le service dit `isVideoOff`, l'overlay attend `isVideoOn`. C'est le
      // genre d'inversion qui passe la relecture et ne se voit qu'à l'usage.
      expect(
        ecran.contains('!meetingService.isParticipantVideoOff(focusedId)'),
        isTrue,
        reason: 'isVideoOn distant doit être la négation de isParticipantVideoOff',
      );
      expect(
        ecran.contains('!meetingService.isVideoOff'),
        isTrue,
        reason: 'isVideoOn local doit être la négation de isVideoOff',
      );
    });
  });

  group('correctifs sans règle propre', () {
    final service =
        File('lib/core/services/meeting_service.dart').readAsStringSync();

    test('le statut repasse par idle, sinon la bannière n’annonce rien', () {
      // `idle` n'était plus jamais écrit après la déclaration du champ : la
      // bannière de session l'attend pour dire « Réunion terminée ».
      expect(service.contains('_status = MeetingStatus.idle'), isTrue);
    });

    test('une session média occupée refuse l’entrée au lieu de la mutiler', () {
      expect(service.contains("throw StateError('SESSION_BUSY')"), isTrue);
      // Surtout pas de libération des rendus ici : le singleton est partagé
      // avec l'appel, et la garde `holdsSession` du cleanup existe pour ça.
      expect(
        RegExp(r'SessionVideoRenderers\.instance\.release\(\)')
            .allMatches(service)
            .length,
        1,
        reason: 'une seule libération, celle du cleanup gardée par holdsSession',
      );
    });

    test('les deux feuilles peuvent grandir', () {
      // Sans `isScrollControlled`, elles sont plafonnées à 9/16 : le clavier
      // recouvrait le chat, et le glissement de la feuille participants était
      // inerte.
      expect(
        RegExp(r'isScrollControlled: true').allMatches(ecran).length,
        2,
        reason: 'la feuille de chat et celle des participants',
      );
    });

    test('la présence vient de la salle, pas des flux', () {
      expect(ecran.contains('meetingService.presentIds'), isTrue);
      expect(
        ecran.contains('Set<String>.from(meetingService.remoteStreams.keys)'),
        isFalse,
        reason: 'un flux mort survit à son propriétaire, et l’inverse',
      );
    });
  });

  group('câblage de l’écran de détail', () {
    final detail = File('lib/screens/meetings/meeting_detail_screen.dart')
        .readAsStringSync();

    test('le badge participant passe par la règle, pas par un accès direct',
        () {
      expect(detail.contains('badgeParticipant('), isTrue);
      // `participant.status == 1` était la lecture directe qui faisait dire
      // « Accepté » à tout invité, rejoint ou non.
      expect(detail.contains('participant.status == 1'), isFalse,
          reason: 'la lecture directe du statut a été remplacée par la règle');
    });

    test('la phase de réunion vient d’un seul endroit', () {
      expect(detail.contains('phaseReunion('), isTrue);
      expect(detail.contains('peutRejoindre('), isTrue);
      // L'ancien calcul dupliqué, recalculé séparément pour la puce et pour le
      // bouton, ce qui les faisait diverger.
      expect(detail.contains('enum _MeetingStatus'), isFalse);
    });
  });
}
