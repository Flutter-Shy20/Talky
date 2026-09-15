import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/meeting/meeting_exit_rules.dart';

void main() {
  group('shouldPopMeetingScreen', () {
    test('réunion terminée, aucune fermeture engagée : on ferme', () {
      expect(
        shouldPopMeetingScreen(
          alreadyClosing: false,
          meetingStatusName: 'ended',
        ),
        isTrue,
      );
    });

    test('fermeture déjà engagée : on ne ferme pas une seconde fois', () {
      // Le défaut S1. Sans cette garde, le bouton popait après le listener, et
      // le second pop retirait la route du dessous — l'accueil, donc l'écran
      // noir, quand la réunion avait été ouverte depuis l'onglet Réunions.
      expect(
        shouldPopMeetingScreen(
          alreadyClosing: true,
          meetingStatusName: 'ended',
        ),
        isFalse,
      );
    });

    test('retour à idle : terminal au même titre que ended', () {
      expect(
        shouldPopMeetingScreen(
          alreadyClosing: false,
          meetingStatusName: 'idle',
        ),
        isTrue,
      );
    });

    test('idle pendant une fermeture engagée : rien non plus', () {
      // F1 fera enchaîner `ended` puis `idle` : deux notifications, une seule
      // fermeture.
      expect(
        shouldPopMeetingScreen(
          alreadyClosing: true,
          meetingStatusName: 'idle',
        ),
        isFalse,
      );
    });

    test('réunion vivante : on ne ferme jamais', () {
      for (final statut in const ['connected', 'joining']) {
        expect(
          shouldPopMeetingScreen(
            alreadyClosing: false,
            meetingStatusName: statut,
          ),
          isFalse,
          reason: 'statut $statut',
        );
      }
    });
  });
}
