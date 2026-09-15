import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Garde-fou contre le retour des erreurs brutes à l'écran.
///
/// L'audit de 09/2026 a retiré 62 sites qui affichaient une exception, un texte
/// serveur ou un chemin de fichier. Rien n'empêche mécaniquement de les
/// réécrire : ce test le fait.
///
/// Il tient en deux volets, parce que la faute avait deux visages :
///
/// 1. **Le trou dans le catalogue.** `"Erreur: {error}"` était traduit en trois
///    langues et n'attendait qu'un argument. Supprimer les gabarits ne suffit
///    pas — il faut interdire d'en recréer.
/// 2. **L'affichage direct.** `Text('$e')`, `e.message`, `e.toString()` dans un
///    écran.
///
/// Modelé sur `l10n_parity_test.dart`, dont il reprend les helpers.
void main() {
  const l10nDir = 'lib/l10n';

  // ── Volet 1 : aucun gabarit ne doit rouvrir un trou ────────────────

  /// Noms de placeholders qui trahissent un gabarit destiné à recevoir une
  /// erreur. `{count}`, `{name}`, `{email}` sont légitimes et absents d'ici.
  const placeholdersInterdits = {
    'error',
    'err',
    'erreur',
    'exception',
    'stacktrace',
    'path',
    'chemin',
    'details',
    'detail',
  };

  /// Mots-clés ICU, à ne pas confondre avec des arguments.
  const motsClesIcu = {'plural', 'select', 'other', 'zero', 'one', 'two',
      'few', 'many', 'date', 'time', 'number'};

  Set<String> placeholdersDe(String valeur) => RegExp(r'\{\s*(\w+)\s*[,}]')
      .allMatches(valeur)
      .map((m) => m.group(1)!)
      .where((nom) => !motsClesIcu.contains(nom))
      .toSet();

  final fichiersArb = Directory(l10nDir)
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.startsWith('app_') && n.endsWith('.arb'))
      .toList()
    ..sort();

  test('des fichiers .arb sont bien surveillés', () {
    expect(fichiersArb, isNotEmpty,
        reason: 'Aucun app_*.arb trouvé — le garde-fou ne surveille rien.');
  });

  for (final nom in fichiersArb) {
    test('$nom — aucun gabarit n\'accepte une erreur en argument', () {
      final arb = jsonDecode(File('$l10nDir/$nom').readAsStringSync())
          as Map<String, dynamic>;

      final fautifs = <String>[];
      arb.forEach((cle, valeur) {
        if (cle.startsWith('@') || valeur is! String) return;
        final interdits =
            placeholdersDe(valeur).where(placeholdersInterdits.contains);
        for (final p in interdits) {
          fautifs.add('$cle → {$p}');
        }
      });

      expect(
        fautifs,
        isEmpty,
        reason: 'Ces clés rouvrent un trou où glisser une exception :\n'
            '  ${fautifs.join('\n  ')}\n\n'
            "Une erreur ne s'affiche pas en la concaténant à une phrase. "
            'Ajouter une clé SANS placeholder au catalogue de '
            'lib/core/errors/error_presenter.dart, et la résoudre depuis le '
            'code serveur ou la nature de la panne.',
      );
    });
  }

  // ── Volet 2 : aucun écran ne doit afficher l'erreur elle-même ──────

  /// Dossiers où vit l'interface. Les services y échappent : ils manipulent
  /// légitimement `e.message` pour journaliser.
  const dossiersInterface = [
    'lib/screens',
    'lib/widgets',
    'lib/providers',
  ];

  /// Ce qu'on ne veut plus voir servir à composer un texte affiché.
  ///
  /// L'interpolation est cherchée dans **toute** chaîne littérale, pas
  /// seulement dans un `Text(...)` : les six helpers privés de l'application
  /// (`_snack`, `_showSnack`, `_showError`, `_afficher`…) prennent une `String`
  /// déjà composée, et `_showSnack('$e')` fuit tout autant que `Text('$e')`.
  final motifsInterdits = <String, RegExp>{
    "interpolation d'une erreur dans une chaîne":
        RegExp(r"""'[^']*\$\{?(e|err|erreur|error|ex)\b"""),
    'e.toString() dans un affichage':
        RegExp(r'\b(e|err|erreur|error|ex)\.toString\(\)'),
    'e.message dans un affichage': RegExp(r'\b(e|err|erreur|error|ex)\.message\b'),
    'snapshot.error affiché': RegExp(r'Text\([^)]*snapshot\.error'),
  };

  /// Lignes exemptées, avec la raison. Une exemption se justifie par écrit ou
  /// elle n'existe pas.
  bool estExempte(String ligne) {
    final nu = ligne.trimLeft();
    // Commentaires et documentation : ils *parlent* du motif.
    if (nu.startsWith('//') || nu.startsWith('///') || nu.startsWith('*')) {
      return true;
    }
    // Journalisation : c'est justement là que le détail doit aller.
    // `AppLog.e(` / `AppLog.w(` autant que `debugPrint(`.
    if (RegExp(r'\b(AppLog\s*\.\s*\w+|debugPrint|print)\s*\(').hasMatch(ligne)) {
      return true;
    }
    // Marqueur explicite, à motiver sur la ligne précédente.
    if (ligne.contains('erreur-brute-ok')) return true;
    return false;
  }

  for (final dossier in dossiersInterface) {
    test('$dossier — aucune erreur brute composée pour l\'écran', () {
      final fautifs = <String>[];
      final dir = Directory(dossier);
      if (!dir.existsSync()) return;

      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart') || f.path.endsWith('.g.dart')) continue;
        final lignes = f.readAsLinesSync();
        for (var i = 0; i < lignes.length; i++) {
          final ligne = lignes[i];
          if (estExempte(ligne)) continue;
          motifsInterdits.forEach((libelle, motif) {
            if (motif.hasMatch(ligne)) {
              fautifs.add('${f.path}:${i + 1} — $libelle\n      '
                  '${ligne.trim()}');
            }
          });
        }
      }

      expect(
        fautifs,
        isEmpty,
        reason: '${fautifs.length} affichage(s) d\'erreur brute :\n\n'
            '  ${fautifs.join('\n\n  ')}\n\n'
            'Passer par presenterErreur(context.l10n, e, domaine: …) ou '
            'afficherErreur(context, e, domaine: …) — voir '
            'lib/core/errors/error_presenter.dart.',
      );
    });
  }
}
