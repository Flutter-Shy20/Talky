import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/l10n/app_localizations.dart';
import 'package:talky_flutter/widgets/chat/message_status_icon.dart';

/// L'accusé passait à l'horloge dès l'insertion locale, puis au ✓ au retour du
/// serveur. Une fois l'aller-retour serveur ramené à trois requêtes, cet ack
/// revient en quelques dizaines de millisecondes : l'horloge n'avait plus le
/// temps que de clignoter. `pendingGrace` la retient le temps de laisser sa
/// chance à un accusé rapide, sans jamais masquer une attente réelle.
///
/// Les cas qui doivent masquer utilisent une fenêtre longue et explicite : le
/// délai réel de 300 ms se mesure sur l'horloge murale, que le temps virtuel de
/// `tester.pump` ne pilote pas.
Widget host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: Scaffold(body: child),
    );

const grace = Duration(seconds: 5);

Finder get _clock => find.byIcon(Icons.schedule);
Finder get _check => find.byIcon(Icons.check);

void main() {
  group('MessageStatusIcon — délai avant l\'horloge', () {
    testWidgets('un envoi tout juste parti n\'affiche pas l\'horloge',
        (tester) async {
      await tester.pumpWidget(host(MessageStatusIcon(
        status: 0,
        pendingSince: DateTime.now(),
        grace: grace,
      )));

      expect(
        _clock,
        findsNothing,
        reason: 'pendant la fenêtre de grâce, l\'horloge ne doit pas '
            'apparaître : un ✓ arrivant juste après ne produirait qu\'un '
            'clignotement',
      );
    });

    testWidgets('elle apparaît une fois le délai écoulé', (tester) async {
      await tester.pumpWidget(host(MessageStatusIcon(
        status: 0,
        pendingSince: DateTime.now(),
        grace: grace,
      )));
      expect(_clock, findsNothing);

      // Le timer interne redéclenche le rendu tout seul, sans nouvel événement.
      await tester.pump(grace);

      expect(
        _clock,
        findsOneWidget,
        reason: 'passé le délai, l\'attente est réelle : la masquer mentirait',
      );
    });

    testWidgets('un envoi déjà ancien affiche l\'horloge sans attendre',
        (tester) async {
      // Fenêtre déjà expirée au montage : aucun timer, affichage immédiat.
      await tester.pumpWidget(host(MessageStatusIcon(
        status: 0,
        pendingSince: DateTime.now().subtract(const Duration(minutes: 1)),
        grace: grace,
      )));

      expect(_clock, findsOneWidget);
    });

    testWidgets('sans instant d\'envoi, comportement d\'origine', (tester) async {
      // Les appelants qui ne renseignent pas `pendingSince` ne doivent rien
      // voir changer.
      await tester.pumpWidget(host(const MessageStatusIcon(status: 0)));

      expect(_clock, findsOneWidget);
    });

    testWidgets('un horodatage dans le futur n\'escamote pas l\'icône',
        (tester) async {
      // Horloge d'appareil décalée : masquer pour une durée imprévisible serait
      // pire que d'afficher tout de suite.
      await tester.pumpWidget(host(MessageStatusIcon(
        status: 0,
        pendingSince: DateTime.now().add(const Duration(minutes: 10)),
        grace: grace,
      )));

      expect(_clock, findsOneWidget);
    });
  });

  group('MessageStatusIcon — le délai ne touche que l\'horloge', () {
    testWidgets('le ✓ s\'affiche immédiatement, c\'est le cas visé',
        (tester) async {
      await tester.pumpWidget(host(MessageStatusIcon(
        status: 1,
        pendingSince: DateTime.now(),
        grace: grace,
      )));

      expect(_check, findsOneWidget);
      expect(_clock, findsNothing);
    });

    testWidgets('un échec reste immédiatement visible', (tester) async {
      await tester.pumpWidget(host(MessageStatusIcon(
        status: 4,
        pendingSince: DateTime.now(),
        grace: grace,
      )));

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('l\'accusé qui arrive pendant le délai ne fait rien clignoter',
        (tester) async {
      final sentAt = DateTime.now();
      await tester.pumpWidget(host(MessageStatusIcon(
        status: 0,
        pendingSince: sentAt,
        grace: grace,
      )));
      expect(_clock, findsNothing);

      // Ack serveur reçu bien avant la fin de la fenêtre : on passe de « rien »
      // à « ✓ », sans que l'horloge ait jamais été montrée.
      await tester.pumpWidget(host(MessageStatusIcon(
        status: 1,
        pendingSince: sentAt,
        grace: grace,
      )));

      expect(_check, findsOneWidget);
      expect(_clock, findsNothing);

      // Le timer armé par l'état précédent ne doit pas réintroduire l'horloge.
      await tester.pump(grace);
      expect(_clock, findsNothing);
      expect(_check, findsOneWidget);
    });
  });

  group('MessageStatusIcon — pas de saut de mise en page', () {
    testWidgets('la place réservée fait la taille de l\'icône', (tester) async {
      const size = 11.0;

      await tester.pumpWidget(host(MessageStatusIcon(
        status: 0,
        size: size,
        pendingSince: DateTime.now(),
        grace: grace,
      )));
      final reserved = tester.getSize(find.descendant(
        of: find.byType(MessageStatusIcon),
        matching: find.byType(SizedBox),
      ));

      await tester.pump(grace);
      final icon = tester.getSize(_clock);

      expect(
        reserved,
        icon,
        reason: 'sans réserve à la bonne taille, l\'arrivée de l\'icône '
            'décalerait l\'heure et ferait sauter la bulle',
      );
    });
  });
}
