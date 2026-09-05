// Le retour arrière pendant un appel vidéo doit ouvrir la vignette système,
// pas fermer l'application.
//
// Android ne prévient de la sortie par `onUserLeaveHint` que pour le bouton
// Accueil : le retour arrière, lui, termine l'activité sans passer par là.
// L'appel mourait donc avec elle, et la première image vidéo livrée après le
// détachement du moteur emportait le processus. `didPopRoute` est le rattrapage
// pour les appareils sous API 31, où l'auto-entrée du système n'existe pas.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/system_pip.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.alanya237.alanya/pip');
  late List<String> appels;
  late bool entreeAcceptee;

  void brancherPont() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      appels.add(call.method);
      return switch (call.method) {
        'enterNow' => entreeAcceptee,
        _ => true,
      };
    });
  }

  setUp(() async {
    appels = [];
    entreeAcceptee = true;
    brancherPont();
    // Singleton : chaque test repart d'une session close.
    await SystemPip.instance.reset();
    appels.clear();
  });

  tearDown(() async {
    await SystemPip.instance.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('hors appel vidéo, le retour arrière ferme l\'application', () async {
    expect(
      await SystemPip.instance.didPopRoute(),
      isFalse,
      reason: 'rien à retenir : le retour arrière doit suivre son cours',
    );
    expect(appels, isNot(contains('enterNow')));
  });

  test('pendant un appel vidéo, le retour arrière ouvre la vignette', () async {
    await SystemPip.instance.setEligible(true);
    appels.clear();

    expect(
      await SystemPip.instance.didPopRoute(),
      isTrue,
      reason: 'le retour est consommé : l\'activité n\'est pas terminée',
    );
    expect(appels, contains('enterNow'));
  });

  test('vignette refusée par la plateforme : on rend la main', () async {
    await SystemPip.instance.setEligible(true);
    entreeAcceptee = false;
    appels.clear();

    expect(
      await SystemPip.instance.didPopRoute(),
      isFalse,
      reason: 'PiP désactivé dans les réglages : l\'application se ferme '
          'comme avant, plutôt que d\'avaler le retour arrière',
    );
  });

  test('appel terminé : le retour arrière redevient une sortie', () async {
    await SystemPip.instance.setEligible(true);
    await SystemPip.instance.reset();
    appels.clear();

    expect(
      await SystemPip.instance.didPopRoute(),
      isFalse,
      reason: 'une éligibilité oubliée ouvrirait une vignette vide',
    );
    expect(appels, isNot(contains('enterNow')));
  });

  test('sans pont natif, le retour arrière suit son cours', () async {
    await SystemPip.instance.setEligible(true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    expect(
      await SystemPip.instance.didPopRoute(),
      isFalse,
      reason: 'MissingPluginException ne doit pas bloquer la sortie',
    );

    brancherPont();
  });
}
