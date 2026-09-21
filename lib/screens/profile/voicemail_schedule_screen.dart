import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/db/app_database.dart';
import '../../core/errors/afficher_erreur.dart';
import '../../core/errors/app_error.dart';
import '../../core/services/call/voicemail_provider.dart';
import '../../core/services/local_cache_repository.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/contact_list_display.dart';
import '../../talky_models.dart';
import '../../widgets/profile/settings_group.dart';
import 'pick_contact_list_sheet.dart';

/// Réglage du répondeur : la règle récurrente (jours et heures) et la liste
/// autorisée à faire sonner malgré tout.
///
/// Même forme que `DndScheduleScreen`, dont il reprend le PATCH optimiste : on
/// met l'écran à jour tout de suite, on envoie, et la réponse du serveur fait
/// foi. Elle porte d'ailleurs plus que ce qu'on a écrit — `active`,
/// `activeUntil`, `resolvedTimezone` sont calculés serveur, et c'est ce qui
/// permet au bandeau de se mettre à jour sans que cet écran n'ait à le lui dire.
///
/// L'activation PONCTUELLE ne se règle pas ici : elle vit dans la feuille
/// d'activation rapide de l'onglet Appels, où l'on choisit une échéance. Cet
/// écran affiche seulement son état et permet de l'éteindre.
class VoicemailScheduleScreen extends StatefulWidget {
  const VoicemailScheduleScreen({super.key});

  @override
  State<VoicemailScheduleScreen> createState() =>
      _VoicemailScheduleScreenState();
}

class _VoicemailScheduleScreenState extends State<VoicemailScheduleScreen> {
  bool _loading = true;
  bool _enabled = false;
  TimeOfDay _start = const TimeOfDay(hour: 22, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 7, minute: 0);
  int _daysBitmask = 127;
  int? _bypassListId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final vm = context.read<VoicemailProvider>();
    await vm.refresh();
    if (!mounted) return;
    setState(() {
      final s = vm.schedule;
      if (s != null) _apply(s);
      _loading = false;
    });
  }

  void _apply(VoicemailSchedule s) {
    _enabled = s.enabled;
    _start = _parseTime(s.startTime, const TimeOfDay(hour: 22, minute: 0));
    _end = _parseTime(s.endTime, const TimeOfDay(hour: 7, minute: 0));
    _daysBitmask = s.daysBitmask;
    _bypassListId = s.bypassListId;
  }

  TimeOfDay _parseTime(String raw, TimeOfDay fallback) {
    final parts = raw.split(':');
    if (parts.length < 2) return fallback;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return fallback;
    return TimeOfDay(hour: h.clamp(0, 23), minute: m.clamp(0, 59));
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _patch(Map<String, dynamic> patch) async {
    final vm = context.read<VoicemailProvider>();
    if (vm.isSaving) return;
    try {
      final next = await vm.patch(patch);
      if (!mounted) return;
      setState(() => _apply(next));
    } catch (e) {
      if (!mounted) return;
      afficherErreur(context, e, domaine: ErrorDomain.appel);
    }
  }

  /// Éteint tout : l'activation ponctuelle et la règle récurrente. Méthode de
  /// l'état plutôt que fermeture posée dans le `build` — `mounted` s'y rapporte
  /// alors au `State`, et non à un `BuildContext` capturé par une fermeture.
  Future<void> _desactiver() async {
    final vm = context.read<VoicemailProvider>();
    try {
      final next = await vm.disable();
      if (!mounted) return;
      setState(() => _apply(next));
    } catch (e) {
      if (!mounted) return;
      afficherErreur(context, e, domaine: ErrorDomain.appel);
    }
  }

  Future<void> _pickTime({required bool isStart}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _start : _end,
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _start = picked;
      } else {
        _end = picked;
      }
    });
    await _patch(
        isStart ? {'startTime': _formatTime(picked)} : {'endTime': _formatTime(picked)});
  }

  bool _isDayActive(int bit) => (_daysBitmask & (1 << bit)) != 0;

  Future<void> _toggleDay(int bit) async {
    final next =
        _isDayActive(bit) ? _daysBitmask & ~(1 << bit) : _daysBitmask | (1 << bit);
    setState(() => _daysBitmask = next);
    await _patch({'daysBitmask': next});
  }

  String _dayLabel(int bit) {
    final l10n = context.l10n;
    return switch (bit) {
      0 => l10n.dndDayMon,
      1 => l10n.dndDayTue,
      2 => l10n.dndDayWed,
      3 => l10n.dndDayThu,
      4 => l10n.dndDayFri,
      5 => l10n.dndDaySat,
      _ => l10n.dndDaySun,
    };
  }

  Future<void> _pickBypassList() async {
    final choix = await showPickContactList(context, selectedId: _bypassListId);
    // `null` = feuille refermée sans choisir. Ce n'est pas « Personne », qui
    // est un choix explicite portant `idList == null`.
    if (choix == null || !mounted) return;
    setState(() => _bypassListId = choix.idList);
    await _patch({'bypassListId': choix.idList});
  }

  /// Le nom de la liste autorisée, lu dans le cache local.
  ///
  /// Une liste supprimée entre-temps fait retomber la colonne à NULL côté base
  /// (ON DELETE SET NULL) : on affiche « Personne » plutôt qu'un nom fantôme.
  String _bypassSubtitle(List<LocalContactList> lists) {
    final l10n = context.l10n;
    if (_bypassListId == null) return l10n.voicemailBypassNobody;
    for (final l in lists) {
      if (l.idList == _bypassListId) return l.displayName(l10n);
    }
    return l10n.voicemailBypassNobody;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final vm = context.watch<VoicemailProvider>();

    return Scaffold(
      backgroundColor: context.semantic.surfaceMuted,
      appBar: AppBar(title: Text(l10n.voicemailScheduleTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                AppSpacing.vGapLg,
                // L'état courant en premier : c'est la question que se pose
                // celui qui ouvre cet écran — « est-ce que ça tourne, là ? ».
                if (vm.isActive)
                  Padding(
                    padding: AppSpacing.screenH,
                    child: Card(
                      color: context.colors.primaryContainer,
                      elevation: 0,
                      child: ListTile(
                        leading: Icon(Icons.voicemail_rounded,
                            color: context.colors.onPrimaryContainer),
                        title: Text(
                          vm.deadline == null
                              ? l10n.voicemailBannerActive
                              : l10n.voicemailBannerUntil(vm.deadline!),
                          style: TextStyle(
                            color: context.colors.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: TextButton(
                          onPressed: vm.isSaving ? null : _desactiver,
                          child: Text(l10n.voicemailBannerDisable),
                        ),
                      ),
                    ),
                  ),
                if (vm.isActive) AppSpacing.vGapXxl,
                SettingsGroup(
                  title: l10n.voicemailScheduleTitle,
                  child: SettingsBoolTile(
                    icon: Icons.voicemail_outlined,
                    title: l10n.voicemailEnabled,
                    subtitle: l10n.voicemailEnabledSubtitle,
                    value: _enabled,
                    onChanged: (v) {
                      setState(() => _enabled = v);
                      _patch({'enabled': v});
                    },
                  ),
                ),
                AppSpacing.vGapXxl,
                SettingsGroup(
                  title: l10n.dndScheduleHours,
                  child: Column(
                    children: [
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xl,
                          vertical: AppSpacing.sm,
                        ),
                        title: Text(l10n.dndStartTime),
                        trailing: Text(
                          _formatTime(_start),
                          style: context.text.bodyLarge?.copyWith(
                            color: context.colors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onTap: () => _pickTime(isStart: true),
                      ),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xl,
                          vertical: AppSpacing.sm,
                        ),
                        title: Text(l10n.dndEndTime),
                        trailing: Text(
                          _formatTime(_end),
                          style: context.text.bodyLarge?.copyWith(
                            color: context.colors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onTap: () => _pickTime(isStart: false),
                      ),
                    ],
                  ),
                ),
                AppSpacing.vGapXxl,
                SettingsGroup(
                  title: l10n.dndDays,
                  child: Padding(
                    padding: AppSpacing.card,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          children: List.generate(7, (bit) {
                            return FilterChip(
                              label: Text(_dayLabel(bit)),
                              selected: _isDayActive(bit),
                              onSelected: (_) => _toggleDay(bit),
                            );
                          }),
                        ),
                        AppSpacing.vGapSm,
                        // Le fuseau réellement utilisé, en clair. Il se résout
                        // par cascade côté serveur — réglage de l'appareil,
                        // puis pays du compte — et sans cette ligne, un compte
                        // rattaché au mauvais pays donnerait un créneau décalé
                        // que rien n'expliquerait.
                        Text(
                          l10n.voicemailTimezoneHint(
                              vm.schedule?.resolvedTimezone ?? ''),
                          style: context.text.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                AppSpacing.vGapXxl,
                StreamBuilder<List<LocalContactList>>(
                  stream: context.read<LocalCacheRepository>().watchContactLists(),
                  builder: (context, snapshot) {
                    final lists = snapshot.data ?? const <LocalContactList>[];
                    return SettingsGroup(
                      title: l10n.voicemailBypassTitle,
                      child: SettingsNavTile(
                        icon: Icons.notifications_active_outlined,
                        title: l10n.voicemailBypassTile,
                        subtitle: _bypassSubtitle(lists),
                        onTap: _pickBypassList,
                      ),
                    );
                  },
                ),
                AppSpacing.vGapXxl,
              ],
            ),
    );
  }
}
