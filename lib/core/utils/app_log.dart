import 'dart:developer' as developer;

/// Signature du rapporteur d'erreurs distant, branché depuis `main.dart` une
/// fois Firebase initialisé.
///
/// `AppLog` ne connaît volontairement pas Crashlytics : c'est un utilitaire de
/// base, requis par des dizaines de fichiers, et l'y coupler ferait dépendre
/// tout le projet de l'initialisation de Firebase. L'injection garde aussi le
/// bon comportement quand cette initialisation échoue (services Google Play
/// absents ou en cours de mise à jour) : le rapporteur reste simplement nul, et
/// la journalisation locale continue.
typedef RapporteurErreur = void Function(
  Object error,
  StackTrace? stack, {
  required bool fatal,
  required String contexte,
});

/// Journalisation centralisée de Talky.
///
/// Remplace les `debugPrint` ad hoc et, surtout, les `catch (_) {}` qui
/// avalaient silencieusement des erreurs réseau/données. Repose sur
/// `dart:developer` (structuré : tag, niveau, erreur, stack — visible dans
/// DevTools et la console), sans dépendance externe.
///
/// Niveaux alignés sur la convention `package:logging` :
/// 700=info, 900=warning, 1000=error.
///
/// Seul le niveau `e` (1000) remonte au rapporteur distant : un avertissement
/// décrit un repli qui a fonctionné, pas un incident. Les faire remonter
/// noierait les vraies erreurs.
class AppLog {
  AppLog._();

  static RapporteurErreur? _rapporteur;

  /// Branche la remontée distante. Appelé une fois, depuis `main.dart`.
  static void brancherRapporteur(RapporteurErreur rapporteur) {
    _rapporteur = rapporteur;
  }

  /// Information de déroulé (peu verbeux).
  static void i(String tag, String message) =>
      _log(tag, message, level: 700);

  /// Avertissement : anomalie non bloquante (best-effort qui a échoué).
  static void w(String tag, String message, [Object? error, StackTrace? st]) =>
      _log(tag, message, level: 900, error: error, st: st);

  /// Erreur : opération importante qui a échoué (réseau, données, parsing…).
  ///
  /// `fatal` distingue ce qui a fait tomber l'écran ou l'application de ce qui
  /// n'a dégradé qu'une opération. Réservé aux gestionnaires globaux de
  /// `main.dart` — un appel ordinaire n'a pas à le poser.
  static void e(
    String tag,
    String message, [
    Object? error,
    StackTrace? st,
    bool fatal = false,
  ]) =>
      _log(tag, message, level: 1000, error: error, st: st, fatal: fatal);

  static void _log(
    String tag,
    String message, {
    int level = 0,
    Object? error,
    StackTrace? st,
    bool fatal = false,
  }) {
    developer.log(
      message,
      name: tag,
      level: level,
      error: error,
      stackTrace: st,
    );

    if (level < 1000 || _rapporteur == null) return;
    // Une erreur dans la remontée d'erreur ne doit jamais faire tomber
    // l'appelant — ni, pire, se rappeler elle-même en boucle.
    try {
      _rapporteur!(
        error ?? message,
        st,
        fatal: fatal,
        contexte: '$tag: $message',
      );
    } catch (_) {}
  }
}
