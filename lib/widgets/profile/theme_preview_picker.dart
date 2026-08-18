import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';

/// Sélecteur de thème à vignettes : trois aperçus miniatures (clair, sombre,
/// système) plutôt que trois libellés.
///
/// Le mode « Système » est le seul des trois dont le nom ne dit pas le
/// résultat ; sa vignette coupée en deux le montre d'un coup d'œil. Les
/// vignettes sont dessinées avec les tokens de `app_colors.dart` — pas des
/// images : elles suivent le thème sans asset à régénérer.
///
/// ⚠️ Les couleurs des vignettes sont **codées en dur par thème**, jamais
/// prises dans le `Theme.of(context)` courant : l'aperçu « clair » doit rester
/// clair quand l'app est en sombre, sinon il n'aperçoit plus rien.
class ThemePreviewPicker extends StatelessWidget {
  const ThemePreviewPicker({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.lightLabel,
    required this.darkLabel,
    required this.systemLabel,
    this.padding = AppSpacing.card,
    this.enabled = true,
  });

  final ThemeMode selected;
  final ValueChanged<ThemeMode> onChanged;
  final String lightLabel;
  final String darkLabel;
  final String systemLabel;

  /// Marge autour de la rangée. `AppSpacing.card` dans un groupe de réglages,
  /// `EdgeInsets.zero` quand l'écran gère déjà ses marges (onboarding).
  final EdgeInsets padding;

  /// Grisé et insensible pendant un enregistrement (onboarding).
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _ThemeCard(
              label: lightLabel,
              selected: selected == ThemeMode.light,
              onTap: () => onChanged(ThemeMode.light),
              panes: const [_Pane.light],
            ),
          ),
          AppSpacing.hGapMd,
          Expanded(
            child: _ThemeCard(
              label: darkLabel,
              selected: selected == ThemeMode.dark,
              onTap: () => onChanged(ThemeMode.dark),
              panes: const [_Pane.dark],
            ),
          ),
          AppSpacing.hGapMd,
          Expanded(
            child: _ThemeCard(
              label: systemLabel,
              selected: selected == ThemeMode.system,
              onTap: () => onChanged(ThemeMode.system),
              panes: const [_Pane.light, _Pane.dark],
            ),
          ),
        ],
      ),
    );

    if (enabled) return row;
    return IgnorePointer(child: Opacity(opacity: 0.5, child: row));
  }
}

/// Une vignette cliquable : l'aperçu, puis son libellé.
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.panes,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final List<_Pane> panes;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.brSm,
      // Semantics **à l'intérieur** de l'InkWell : à l'extérieur, son
      // `excludeSemantics` avalerait l'action de tap et la vignette ne
      // s'annoncerait plus comme actionnable.
      child: Semantics(
        // `inMutuallyExclusiveGroup` fait annoncer « 1 sur 3 » par TalkBack et
        // VoiceOver, ce qu'une simple carte tappable ne dit pas.
        inMutuallyExclusiveGroup: true,
        selected: selected,
        label: label,
        // Sans ça, le libellé du `Text` s'ajoute à celui d'ici et la vignette
        // s'annonce « Clair Clair ».
        excludeSemantics: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 0.8,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  borderRadius: AppRadius.brSm,
                  border: Border.all(
                    // Non sélectionnée, la vignette « Clair » est blanche sur
                    // une carte blanche (et « Sombre » quasi noire sur une
                    // carte sombre) : son contour est la seule chose qui la
                    // détoure. Les jetons `outline` s'inversent entre les deux
                    // thèmes ici — voir le commentaire du Switch dans
                    // app_theme.dart — donc on dérive le trait de
                    // `onSurfaceVariant`, lisible sur les deux fonds.
                    color: selected
                        ? colors.primary
                        : colors.onSurfaceVariant.withValues(alpha: 0.35),
                    width: selected ? 2 : 1,
                  ),
                ),
                // Le contenu est peint jusqu'au bord interne de la bordure.
                clipBehavior: Clip.antiAlias,
                child: Row(
                  children: [
                    for (final pane in panes) Expanded(child: _PanePreview(pane)),
                  ],
                ),
              ),
            ),
            AppSpacing.vGapSm,
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.labelMedium?.copyWith(
                color: selected ? colors.primary : colors.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Les deux palettes que les vignettes savent peindre.
enum _Pane { light, dark }

/// Moitié (ou totalité) d'une vignette : un fond, quelques barres de texte
/// simulées, dont la première prend la couleur d'accent du thème représenté.
class _PanePreview extends StatelessWidget {
  const _PanePreview(this.pane);

  final _Pane pane;

  Color get _background => pane == _Pane.light
      ? AppColors.surface
      : AppColors.darkSurface;

  Color get _line => pane == _Pane.light
      ? AppColors.outlineStrong
      : AppColors.darkOutline;

  Color get _accent => pane == _Pane.light
      ? AppSemanticColors.light.onBrandContainer
      : AppSemanticColors.dark.onBrandContainer;

  @override
  Widget build(BuildContext context) {
    // Largeurs décroissantes : lit comme un écran de texte, pas comme un
    // dégradé de couleur.
    const widths = [0.62, 1.0, 0.78, 0.55];
    return Container(
      color: _background,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < widths.length; i++) ...[
            if (i > 0) AppSpacing.vGapXs,
            FractionallySizedBox(
              widthFactor: widths[i],
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  color: i == 0 ? _accent : _line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
