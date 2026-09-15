import 'package:flutter/material.dart';

import '../navigation/app_navigator.dart';
import '../theme/app_theme.dart';
import 'app_error.dart';
import 'error_presenter.dart';

/// Affiche une erreur en SnackBar, traduite par [presenterErreur].
///
/// Prend l'erreur **brute** et jamais une `String` déjà composée : l'appelant
/// n'a aucun moyen de glisser un texte ici, donc aucun moyen de retomber dans
/// `showSnackBar(Text('$e'))`. Un écran qui sait dire mieux que le repli de son
/// domaine appelle `presenterErreur` et compose sa propre SnackBar.
void afficherErreur(
  BuildContext context,
  Object? erreur, {
  required ErrorDomain domaine,
}) {
  if (!context.mounted) return;
  final texte = presenterErreur(context.l10n, erreur, domaine: domaine);
  _montrer(ScaffoldMessenger.maybeOf(context), texte, context.colors.error);
}

/// Variante sans `BuildContext`, pour les services.
///
/// Passe par [appMessengerKey], déjà branchée sur `MaterialApp` et déjà
/// utilisée par `CallService` pour ses messages d'appel occupé ou sans réponse.
void afficherErreurGlobale(Object? erreur, {required ErrorDomain domaine}) {
  final texte = presenterErreurGlobale(erreur, domaine: domaine);
  _montrer(appMessengerKey.currentState, texte, null);
}

void _montrer(ScaffoldMessengerState? messenger, String texte, Color? fond) {
  if (messenger == null) {
    // Rien à faire : le texte est déjà parti dans les journaux via le
    // presenter, donc l'incident reste diagnosticable.
    return;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(texte),
      backgroundColor: fond,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
    ));
}
