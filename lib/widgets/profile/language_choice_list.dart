import 'package:flutter/material.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/locale_controller.dart';

/// Liste des langues d'interface, partagée par les réglages et l'onboarding.
///
/// Elle boucle sur [kForcedLocalePreferences] au lieu d'énumérer les langues à
/// la main : ajouter une langue ne demande plus de retoucher les deux écrans —
/// c'est précisément ce que les anciens `SegmentedButton` écrits en dur
/// laissaient passer.
///
/// Les libellés viennent de [nativeLabelOf], donc jamais de l'ARB : voir la
/// note qui accompagne cette fonction.
class LanguageChoiceList extends StatelessWidget {
  const LanguageChoiceList({
    super.key,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
    this.contentPadding = defaultContentPadding,
  });

  final AppLocalePreference selected;
  final ValueChanged<AppLocalePreference> onChanged;
  final bool enabled;

  /// Marge interne des tuiles. Par défaut alignée sur les autres tuiles de
  /// réglages ; l'onboarding, qui gère déjà ses marges, passe `EdgeInsets.zero`.
  final EdgeInsets contentPadding;

  static const EdgeInsets defaultContentPadding = EdgeInsets.symmetric(
    horizontal: AppSpacing.xl,
    vertical: AppSpacing.xs,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.colors;

    // `SettingsGroup` pose un `Container` coloré autour de son enfant, qui
    // s'intercale entre les tuiles et le `Material` le plus proche : sans ce
    // Material transparent, Flutter avertit que les ondes de tap seront
    // peintes sous le fond, donc invisibles.
    final group = RadioGroup<AppLocalePreference>(
      groupValue: selected,
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
      child: Column(
        children: [
          // « Système » est un mode, pas une langue : il ouvre la liste et dit
          // ce qu'il résout ici et maintenant.
          RadioListTile<AppLocalePreference>(
            value: AppLocalePreference.system,
            contentPadding: contentPadding,
            title: Text(
              l10n.settingsLangSystem,
              style:
                  context.text.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
              l10n.settingsLangSystemResolved(
                nativeLabelOf(platformResolvedPreference())!,
              ),
              style: context.text.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          for (final preference in kForcedLocalePreferences)
            RadioListTile<AppLocalePreference>(
              value: preference,
              contentPadding: contentPadding,
              title: Text(
                // Non-nul par construction : `kForcedLocalePreferences` ne
                // contient que des langues forcées.
                nativeLabelOf(preference)!,
                style: context.text.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
        ],
      ),
    );

    final inked = Material(type: MaterialType.transparency, child: group);
    if (enabled) return inked;

    // `RadioGroup.onChanged` est requis et non nullable : l'état désactivé se
    // rend en coupant les pointeurs, pas en passant `null`.
    return IgnorePointer(
      child: Opacity(opacity: 0.5, child: inked),
    );
  }
}
