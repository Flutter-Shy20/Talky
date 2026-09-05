import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../call_session_guard.dart';

/// Picture-in-Picture système : la fenêtre que l'OS conserve à l'écran quand on
/// quitte l'application pendant un appel vidéo.
///
/// À ne pas confondre avec `SessionVideoWindow`, qui flotte **dans**
/// l'application. Les deux se relaient : la fenêtre Flutter tant qu'on reste
/// dans Alanya, celle du système une fois dehors.
///
/// Côté Android, tout est délégué à la plateforme — c'est l'activité entière
/// qui est réduite, d'où la disposition dédiée que déclenche [isInPipMode] :
/// dans une vignette, tout ce qui n'est pas l'image du correspondant est du
/// bruit. Côté iOS, le pont porte le même nom de canal et les mêmes méthodes.
class SystemPip extends ChangeNotifier with WidgetsBindingObserver {
  SystemPip._();
  static final SystemPip instance = SystemPip._();

  static const _channel = MethodChannel('com.alanya237.alanya/pip');

  bool _isInPipMode = false;
  bool _eligible = false;
  bool _wired = false;

  /// L'application est actuellement affichée en vignette système.
  bool get isInPipMode => _isInPipMode;

  /// Branche l'écoute des transitions. Idempotent.
  void ensureWired() {
    if (_wired || kIsWeb) return;
    _wired = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onPipModeChanged') return null;
      final inPip = call.arguments == true;
      if (_isInPipMode == inPip) return null;
      _isInPipMode = inPip;
      // Le garde décide du sort de la caméra : en PiP l'activité est en pause
      // tout en restant visible, et lui seul ne peut pas le savoir.
      CallSessionGuard.instance.setSystemPipActive(inPip);
      notifyListeners();
      return null;
    });
  }

  /// Dit à la plateforme si quitter l'application doit ouvrir une vignette.
  ///
  /// Appelée aux bornes de session plutôt qu'au moment de la sortie : Android
  /// n'accepte `enterPictureInPictureMode` que depuis `onUserLeaveHint`, donc
  /// l'éligibilité doit déjà être connue quand l'utilisateur appuie sur
  /// Accueil.
  Future<void> setEligible(bool eligible) async {
    if (kIsWeb) return;
    ensureWired();
    if (_eligible == eligible) return;
    _eligible = eligible;
    // L'observateur ne vit que le temps de l'appel, et son inscription tardive
    // est ce qui le rend sûr : voir [didPopRoute].
    if (eligible) {
      WidgetsBinding.instance.addObserver(this);
    } else {
      WidgetsBinding.instance.removeObserver(this);
    }
    try {
      await _channel.invokeMethod('setEligible', {'eligible': eligible});
    } on MissingPluginException {
      // Plateforme sans pont (web, tests) : l'appel se déroule sans vignette.
    } catch (e) {
      debugPrint('[SystemPip] ** setEligible: $e');
    }
  }

  /// Ouvre la vignette tout de suite, l'application étant encore au premier
  /// plan. Passé `onPause`, Android refuse.
  Future<bool> enterNow() async {
    if (kIsWeb) return false;
    try {
      return await _channel.invokeMethod<bool>('enterNow') == true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('[SystemPip] ** enterNow: $e');
      return false;
    }
  }

  /// Le retour arrière allait fermer l'application : on ouvre la vignette.
  ///
  /// Android ne prévient de la sortie par `onUserLeaveHint` que pour le bouton
  /// Accueil. Le retour arrière, lui, *termine* l'activité sans passer par là :
  /// l'appel vidéo mourait avec elle. Sur API 31+ l'auto-entrée du système
  /// couvre déjà ce chemin ; en dessous, ceci est le seul rattrapage.
  ///
  /// L'ordre d'inscription fait tout : `handlePopRoute` interroge les
  /// observateurs dans l'ordre où ils se sont inscrits et s'arrête au premier
  /// qui répond « pris en charge ». Celui-ci ne s'inscrit qu'à l'ouverture d'un
  /// appel vidéo, donc longtemps après le `Navigator` de `WidgetsApp` : la
  /// navigation interne garde la priorité, et on ne voit passer que le retour
  /// arrière que personne n'a voulu — celui qui quitterait l'application.
  ///
  /// Répondre `false` quand l'entrée échoue (PiP désactivé dans les réglages,
  /// profil qui l'interdit) rend la main : l'application se ferme comme avant.
  @override
  Future<bool> didPopRoute() async {
    if (!_eligible || _isInPipMode) return false;
    return enterNow();
  }

  /// Remise à zéro en fin de session : sans elle, une éligibilité oubliée
  /// ouvrirait une vignette pour un appel terminé.
  Future<void> reset() async {
    _isInPipMode = false;
    await setEligible(false);
    notifyListeners();
  }
}
