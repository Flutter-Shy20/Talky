import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';

// ── Clés SharedPreferences ────────────────────────────────────────────────
const _kMsgEnabled    = 'notif_msg_enabled';
const _kMsgSound      = 'notif_msg_sound';
const _kMsgVibration  = 'notif_msg_vibration';
const _kMsgPreview    = 'notif_msg_preview';
const _kMeetEnabled   = 'notif_meet_enabled';
const _kMeetReminder  = 'notif_meet_reminder';
const _kCallEnabled   = 'notif_call_enabled';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  bool _msgEnabled   = true;
  bool _msgSound     = true;
  bool _msgVibration = true;
  bool _msgPreview   = true;
  bool _meetEnabled  = true;
  bool _meetReminder = true;
  bool _callEnabled  = true;

  late SharedPreferences _prefs;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _msgEnabled   = _prefs.getBool(_kMsgEnabled)   ?? true;
      _msgSound     = _prefs.getBool(_kMsgSound)     ?? true;
      _msgVibration = _prefs.getBool(_kMsgVibration) ?? true;
      _msgPreview   = _prefs.getBool(_kMsgPreview)   ?? true;
      _meetEnabled  = _prefs.getBool(_kMeetEnabled)  ?? true;
      _meetReminder = _prefs.getBool(_kMeetReminder) ?? true;
      _callEnabled  = _prefs.getBool(_kCallEnabled)  ?? true;
      _ready = true;
    });
  }

  void _set(String key, bool value) {
    _prefs.setBool(key, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.semantic.surfaceMuted,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Notifications'),
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                AppSpacing.vGapLg,
                _buildSectionLabel('Messages'),
                _buildGroup([
                  _buildToggle(
                    icon: CupertinoIcons.chat_bubble_2,
                    title: 'Notifications de messages',
                    value: _msgEnabled,
                    onChanged: (v) {
                      setState(() => _msgEnabled = v);
                      _set(_kMsgEnabled, v);
                    },
                  ),
                  _buildDivider(),
                  _buildToggle(
                    icon: CupertinoIcons.speaker_2,
                    title: 'Son',
                    value: _msgSound,
                    enabled: _msgEnabled,
                    onChanged: (v) {
                      setState(() => _msgSound = v);
                      _set(_kMsgSound, v);
                    },
                  ),
                  _buildDivider(),
                  _buildToggle(
                    icon: CupertinoIcons.waveform,
                    title: 'Vibration',
                    value: _msgVibration,
                    enabled: _msgEnabled,
                    onChanged: (v) {
                      setState(() => _msgVibration = v);
                      _set(_kMsgVibration, v);
                    },
                  ),
                  _buildDivider(),
                  _buildToggle(
                    icon: CupertinoIcons.eye,
                    title: 'Aperçu du message',
                    subtitle: 'Affiche le texte dans la notification',
                    value: _msgPreview,
                    enabled: _msgEnabled,
                    onChanged: (v) {
                      setState(() => _msgPreview = v);
                      _set(_kMsgPreview, v);
                    },
                  ),
                ]),
                AppSpacing.vGapXxl,
                _buildSectionLabel('Réunions'),
                _buildGroup([
                  _buildToggle(
                    icon: CupertinoIcons.video_camera,
                    title: 'Notifications de réunions',
                    value: _meetEnabled,
                    onChanged: (v) {
                      setState(() => _meetEnabled = v);
                      _set(_kMeetEnabled, v);
                    },
                  ),
                  _buildDivider(),
                  _buildToggle(
                    icon: CupertinoIcons.bell,
                    title: 'Rappels de réunion',
                    subtitle: 'Rappel avant le début d\'une réunion',
                    value: _meetReminder,
                    enabled: _meetEnabled,
                    onChanged: (v) {
                      setState(() => _meetReminder = v);
                      _set(_kMeetReminder, v);
                    },
                  ),
                ]),
                AppSpacing.vGapXxl,
                _buildSectionLabel('Appels'),
                _buildGroup([
                  _buildToggle(
                    icon: CupertinoIcons.phone,
                    title: 'Notifications d\'appels',
                    subtitle: 'Appels entrants et manqués',
                    value: _callEnabled,
                    onChanged: (v) {
                      setState(() => _callEnabled = v);
                      _set(_kCallEnabled, v);
                    },
                  ),
                ]),
                const SizedBox(height: AppSpacing.xxxl),
              ],
            ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl, vertical: AppSpacing.sm),
      child: Text(
        label,
        style: context.text.labelMedium?.copyWith(
            color: context.colors.primary, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildGroup(List<Widget> children) {
    return Container(
      color: context.colors.surface,
      child: Column(children: children),
    );
  }

  Widget _buildDivider() {
    return const Divider(
        height: 1, indent: AppSpacing.xl + AppSpacing.xl + AppSpacing.md);
  }

  Widget _buildToggle({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    bool enabled = true,
    required ValueChanged<bool> onChanged,
  }) {
    final effectiveColor = enabled
        ? context.colors.onSurfaceVariant
        : context.colors.outlineVariant;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl, vertical: AppSpacing.xs),
      leading: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: enabled
              ? AppColors.brandContainer
              : context.semantic.surfaceMuted,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: effectiveColor, size: AppIconSize.md),
      ),
      title: Text(
        title,
        style: context.text.bodyLarge?.copyWith(
          fontWeight: FontWeight.w500,
          color: enabled
              ? context.colors.onSurface
              : context.colors.onSurfaceVariant,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            )
          : null,
      trailing: Switch(
        value: value && enabled,
        onChanged: enabled ? onChanged : null,
        activeThumbColor: context.colors.primary,
      ),
    );
  }
}
