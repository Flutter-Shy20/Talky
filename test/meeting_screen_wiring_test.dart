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
}
