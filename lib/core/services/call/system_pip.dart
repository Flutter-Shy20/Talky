import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
class SystemPip extends ChangeNotifier {
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
    try {
      await _channel.invokeMethod('setEligible', {'eligible': eligible});
    } on MissingPluginException {
      // Plateforme sans pont (web, tests) : l'appel se déroule sans vignette.
    } catch (e) {
      debugPrint('[SystemPip] ** setEligible: $e');
    }
  }

  /// Remise à zéro en fin de session : sans elle, une éligibilité oubliée
  /// ouvrirait une vignette pour un appel terminé.
  Future<void> reset() async {
    _isInPipMode = false;
    await setEligible(false);
    notifyListeners();
  }
}
