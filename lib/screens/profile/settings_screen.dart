import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_settings_sync_service.dart';
import '../../core/services/media_download_preferences.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/locale_controller.dart';
import '../../core/theme/theme_controller.dart';
import '../../providers/chat_provider.dart';
import '../../core/db/app_database.dart';
import '../../widgets/profile/settings_group.dart';
import '../../widgets/profile/theme_preview_picker.dart';
import 'about_legal_screen.dart';
import 'accessibility_screen.dart';
import 'language_screen.dart';
import 'muted_conversations_screen.dart' show isConversationMuted, MutedConversationsScreen;
import 'network_data_screen.dart';
import 'notification_settings_screen.dart';
import 'ringtone_settings_screen.dart';
import 'playback_speed_screen.dart';
import 'storage_screen.dart';
import '../../core/services/ringtone_preferences.dart';
import '../../core/services/translation/translation_languages.dart';
import '../../core/services/translation/translation_settings.dart';
import 'translation_settings_screen.dart';

/// Hub des réglages, en six sections.
///
/// L'ordre suit ce qu'on vient y chercher, et aucune section ne contient un
/// seul réglage orphelin : « Appels » et « Traduction », qui n'en portaient
/// qu'un chacune, ont rejoint Communication et Langues. La vitesse de lecture
/// est descendue dans Médias — c'est de la lecture de médias, pas un réglage
/// d'application — et l'accessibilité est remontée dans Apparence, dont elle
/// règle la taille du texte.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  int _countMuted(List<LocalConversation> convs) =>
      convs.where(isConversationMuted).length;

  Future<void> _push(BuildContext context, Widget screen) => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => screen),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: context.semantic.surfaceMuted,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(l10n.settingsTitle),
      ),
      body: ListView(
        children: [
          AppSpacing.vGapLg,

          // --- Communication -------------------------------------------------
          SettingsGroup(
            title: l10n.settingsSectionCommunication,
            child: Column(
              children: [
                SettingsNavTile(
                  icon: Icons.notifications_outlined,
                  title: l10n.settingsNotifications,
                  subtitle: l10n.settingsNotificationsSubtitle,
                  onTap: () =>
                      _push(context, const NotificationSettingsScreen()),
                ),
                StreamBuilder<List<LocalConversation>>(
                  stream: context.read<ChatProvider>().watchConversations(),
                  builder: (context, snapshot) {
                    final count = _countMuted(snapshot.data ?? []);
                    return SettingsNavTile(
                      icon: Icons.notifications_off_outlined,
                      title: l10n.settingsMutedConversations,
                      subtitle: count == 0
                          ? l10n.mutedConversationsEmpty
                          : l10n.mutedConversationsCount(count),
                      onTap: () =>
                          _push(context, const MutedConversationsScreen()),
                    );
                  },
                ),
                Consumer<RingtonePreferences>(
                  builder: (_, prefs, __) => SettingsNavTile(
                    icon: Icons.music_note_outlined,
                    title: l10n.settingsRingtone,
                    subtitle: prefs.selectedId == RingtoneOption.systemId
                        ? l10n.ringtoneSystemDefaultLabel
                        : prefs.selected.label,
                    onTap: () =>
                        _push(context, const RingtoneSettingsScreen()),
                  ),
                ),
              ],
            ),
          ),
          AppSpacing.vGapXxl,

          // --- Apparence -----------------------------------------------------
          SettingsGroup(
            title: l10n.settingsAppearance,
            child: Column(
              children: [
                Consumer<ThemeController>(
                  builder: (_, tc, __) => ThemePreviewPicker(
                    selected: tc.mode,
                    lightLabel: l10n.settingsThemeLight,
                    darkLabel: l10n.settingsThemeDark,
                    systemLabel: l10n.settingsThemeSystem,
                    onChanged: (mode) => _setThemeMode(context, tc, mode),
                  ),
                ),
                Divider(height: 1, color: context.colors.outlineVariant),
                SettingsNavTile(
                  icon: Icons.accessibility_new_outlined,
                  title: l10n.settingsAccessibility,
                  subtitle: l10n.settingsAccessibilitySubtitle,
                  onTap: () => _push(context, const AccessibilityScreen()),
                ),
              ],
            ),
          ),
          AppSpacing.vGapXxl,

          // --- Langues -------------------------------------------------------
          // Les deux réglages de langue se suivent : sans ça, rien ne dit que
          // l'un vise l'interface et l'autre les messages reçus.
          SettingsGroup(
            title: l10n.settingsSectionLanguages,
            child: Column(
              children: [
                Consumer<LocaleController>(
                  builder: (_, lc, __) => SettingsNavTile(
                    icon: Icons.language,
                    title: l10n.settingsAppLanguage,
                    // En mode système, la tuile dit les deux : le mode choisi
                    // et la langue qu'il donne réellement.
                    subtitle: nativeLabelOf(lc.preference) ??
                        '${l10n.settingsLangSystem} · '
                            '${nativeLabelOf(platformResolvedPreference())!}',
                    onTap: () => _push(context, const LanguageScreen()),
                  ),
                ),
                Consumer<TranslationSettings>(
                  builder: (_, settings, __) => SettingsNavTile(
                    icon: Icons.translate_outlined,
                    title: l10n.settingsMessageTranslation,
                    subtitle: settings.auto
                        ? nativeNameOf(settings.target)
                        : l10n.translateModeNever,
                    onTap: () =>
                        _push(context, const TranslationSettingsScreen()),
                  ),
                ),
              ],
            ),
          ),
          AppSpacing.vGapXxl,

          // --- Médias --------------------------------------------------------
          // Enregistrer dans la galerie était enfoui dans Réseau et données,
          // sous un libellé qui ne disait pas « galerie ». Il remonte ici, avec
          // le téléchargement automatique dont il ne se lit pas séparément.
          SettingsGroup(
            title: l10n.settingsMedia,
            child: Column(
              children: [
                Consumer<MediaDownloadPreferences>(
                  builder: (_, prefs, __) => Column(
                    children: [
                      SettingsBoolTile(
                        icon: Icons.photo_library_outlined,
                        title: l10n.settingsMediaVisibility,
                        subtitle: l10n.settingsMediaVisibilitySubtitle,
                        value: prefs.mediaVisibility,
                        onChanged: prefs.setMediaVisibility,
                      ),
                      SettingsBoolTile(
                        icon: Icons.download_rounded,
                        title: l10n.settingsAutoDownload,
                        subtitle: l10n.settingsAutoDownloadSubtitle,
                        value: prefs.autoDownload,
                        onChanged: prefs.setAutoDownload,
                      ),
                    ],
                  ),
                ),
                SettingsNavTile(
                  icon: Icons.speed_outlined,
                  title: l10n.playbackSpeed,
                  onTap: () => _push(context, const PlaybackSpeedScreen()),
                ),
              ],
            ),
          ),
          AppSpacing.vGapXxl,

          // --- Application ---------------------------------------------------
          SettingsGroup(
            title: l10n.settingsSectionApplication,
            child: Column(
              children: [
                SettingsNavTile(
                  icon: Icons.sd_storage_outlined,
                  title: l10n.settingsStorage,
                  subtitle: l10n.settingsStorageSubtitle,
                  onTap: () => _push(context, const StorageScreen()),
                ),
                SettingsNavTile(
                  icon: Icons.wifi,
                  title: l10n.settingsNetwork,
                  subtitle: l10n.settingsNetworkSubtitle,
                  onTap: () => _push(context, const NetworkDataScreen()),
                ),
              ],
            ),
          ),
          AppSpacing.vGapXxl,

          // --- Informations --------------------------------------------------
          SettingsGroup(
            title: l10n.settingsSectionInformation,
            child: SettingsNavTile(
              icon: Icons.info_outline,
              title: l10n.settingsAbout,
              onTap: () => _push(context, const AboutLegalScreen()),
            ),
          ),
          AppSpacing.vGapXxl,
        ],
      ),
    );
  }

  Future<void> _setThemeMode(
    BuildContext context,
    ThemeController controller,
    ThemeMode mode,
  ) async {
    await controller.setMode(mode);
    if (!context.mounted) return;
    try {
      final sync = context.read<AppSettingsSyncService>();
      await sync.patchAndSync(
        {'themeMode': sync.themeModeToString(mode)},
        theme: controller,
      );
    } catch (_) {
      // Le thème est déjà appliqué et persisté localement : un échec de
      // synchro ne doit pas le rendre inopérant. Comportement inchangé.
    }
  }
}
