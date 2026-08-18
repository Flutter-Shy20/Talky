import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_settings_sync_service.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/locale_controller.dart';
import '../../core/services/translation/translation_languages.dart';
import '../../core/services/translation/translation_settings.dart';
import '../../widgets/profile/language_choice_list.dart';
import '../../widgets/profile/settings_group.dart';
import 'translation_settings_screen.dart';

/// Choix de la langue de l'interface.
///
/// Remplace le `SegmentedButton` à quatre segments qui tronquait ses libellés
/// dès l'arrivée du chinois. Une liste tient à trois comme à trente langues, et
/// suit ce que font déjà Sonnerie, Vitesse de lecture et Traduction — tous des
/// sous-écrans.
class LanguageScreen extends StatelessWidget {
  const LanguageScreen({super.key});

  Future<void> _select(
    BuildContext context,
    LocaleController controller,
    AppLocalePreference preference,
  ) async {
    await controller.setPreference(preference);
    if (!context.mounted) return;
    try {
      final sync = context.read<AppSettingsSyncService>();
      await sync.patchAndSync(
        {'locale': sync.localeToString(preference)},
        locale: controller,
      );
    } catch (_) {
      // La préférence locale est déjà persistée : un échec de synchro ne doit
      // pas empêcher la langue de changer. Comportement inchangé.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: context.semantic.surfaceMuted,
      appBar: AppBar(title: Text(l10n.settingsLanguage)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl,
              AppSpacing.lg,
              AppSpacing.xl,
              0,
            ),
            child: Text(
              l10n.languageScreenHint,
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
          AppSpacing.vGapMd,
          SettingsGroup(
            title: l10n.settingsAppLanguage,
            child: Consumer<LocaleController>(
              builder: (_, controller, __) => LanguageChoiceList(
                selected: controller.preference,
                onChanged: (preference) =>
                    _select(context, controller, preference),
              ),
            ),
          ),
          AppSpacing.vGapXxl,
          // Raccourci volontaire : quelqu'un qui vient chercher « la langue »
          // cherche parfois celle des messages reçus. Le renvoyer d'ici évite
          // un retour arrière et rend la distinction explicite.
          SettingsGroup(
            title: l10n.languageSectionMessages,
            child: Consumer<TranslationSettings>(
              builder: (_, settings, __) => SettingsNavTile(
                icon: Icons.translate_outlined,
                title: l10n.settingsMessageTranslation,
                subtitle: settings.auto
                    ? nativeNameOf(settings.target)
                    : l10n.translateModeNever,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const TranslationSettingsScreen(),
                  ),
                ),
              ),
            ),
          ),
          AppSpacing.vGapXxl,
        ],
      ),
    );
  }
}
