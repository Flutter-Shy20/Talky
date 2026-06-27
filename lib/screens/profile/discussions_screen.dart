import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/db/app_database.dart';
import '../../core/db/chat_dao.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';

class DiscussionsScreen extends StatefulWidget {
  const DiscussionsScreen({super.key});

  @override
  State<DiscussionsScreen> createState() => _DiscussionsScreenState();
}

class _DiscussionsScreenState extends State<DiscussionsScreen> {
  static const _kFontSizeKey = 'chat_font_size';

  double _fontSize = 14;

  @override
  void initState() {
    super.initState();
    _loadFontSize();
  }

  Future<void> _loadFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _fontSize = prefs.getDouble(_kFontSizeKey) ?? 14);
  }

  Future<void> _saveFontSize(double size) async {
    setState(() => _fontSize = size);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kFontSizeKey, size);
  }

  Future<void> _archiveAll() async {
    final db = Provider.of<AppDatabase>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final dao = ChatDao(db);
    final convs = await dao.watchConversations().first;
    for (final c in convs) {
      await dao.setArchived(c.conversID, true);
    }
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Toutes les discussions ont été archivées')),
    );
  }

  Future<void> _clearAllMessages() async {
    final db = Provider.of<AppDatabase>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await _confirm(
      title: 'Vider toutes les discussions',
      message:
          'Tous les messages seront supprimés définitivement. Les conversations resteront visibles. Cette action est irréversible.',
      confirmLabel: 'Vider',
    );
    if (!confirmed) return;
    await db.delete(db.localMessages).go();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Messages supprimés')),
    );
  }

  Future<void> _deleteAll() async {
    final db = Provider.of<AppDatabase>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final dao = ChatDao(db);
    final confirmed = await _confirm(
      title: 'Supprimer toutes les discussions',
      message:
          'Toutes les conversations et leurs messages seront définitivement supprimés. Cette action est irréversible.',
      confirmLabel: 'Supprimer',
      isDangerous: true,
    );
    if (!confirmed) return;
    await dao.clearAll();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Toutes les discussions ont été supprimées')),
    );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool isDangerous = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: isDangerous
                ? TextButton.styleFrom(foregroundColor: AppColors.error)
                : null,
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
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
        title: const Text('Discussions'),
      ),
      body: ListView(
        children: [
          AppSpacing.vGapLg,
          _buildSectionLabel('Apparence'),
          _buildThemeSelector(),
          AppSpacing.vGapXxl,
          _buildSectionLabel('Taille de la police'),
          _buildFontSizeSelector(),
          AppSpacing.vGapXxl,
          _buildSectionLabel('Conversations'),
          _buildConversationsGroup(),
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

  Widget _buildThemeSelector() {
    return Container(
      color: context.colors.surface,
      padding: AppSpacing.card,
      child: Consumer<ThemeController>(
        builder: (_, tc, __) => SegmentedButton<ThemeMode>(
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            minimumSize: const Size(0, AppSizes.buttonHeight),
          ),
          segments: const [
            ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(Icons.wb_sunny_outlined),
              label: Text('Clair'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(Icons.nights_stay_outlined),
              label: Text('Sombre'),
            ),
            ButtonSegment(
              value: ThemeMode.system,
              icon: Icon(Icons.brightness_auto_outlined),
              label: Text('Système'),
            ),
          ],
          selected: {tc.mode},
          onSelectionChanged: (s) => tc.setMode(s.first),
        ),
      ),
    );
  }

  Widget _buildFontSizeSelector() {
    const sizes = <(String, double)>[
      ('Petit', 12),
      ('Moyen', 14),
      ('Grand', 17),
    ];

    return Container(
      color: context.colors.surface,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: sizes.map(((String label, double size) entry) {
              final selected = _fontSize == entry.$2;
              return GestureDetector(
                onTap: () => _saveFontSize(entry.$2),
                child: AnimatedContainer(
                  duration: AppDurations.fast,
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: selected
                        ? context.colors.primary
                        : context.semantic.surfaceMuted,
                    borderRadius: AppRadius.brSm,
                  ),
                  child: Text(
                    entry.$1,
                    style: TextStyle(
                      fontSize: entry.$2,
                      fontWeight: FontWeight.w500,
                      color: selected
                          ? AppColors.white
                          : context.colors.onSurface,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          AppSpacing.vGapLg,
          Container(
            width: double.infinity,
            padding: AppSpacing.card,
            decoration: BoxDecoration(
              color: context.semantic.surfaceMuted,
              borderRadius: AppRadius.brSm,
            ),
            child: Text(
              'Aperçu du texte dans les conversations.',
              style: context.text.bodyMedium?.copyWith(fontSize: _fontSize),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationsGroup() {
    return Container(
      color: context.colors.surface,
      child: Column(
        children: [
          _buildActionTile(
            icon: CupertinoIcons.archivebox,
            title: 'Archiver toutes les discussions',
            onTap: _archiveAll,
          ),
          const Divider(height: 1, indent: AppSpacing.xl + AppSpacing.xl + AppSpacing.md),
          _buildActionTile(
            icon: CupertinoIcons.clear_circled,
            title: 'Vider toutes les discussions',
            subtitle: 'Supprime les messages, conserve les conversations',
            onTap: _clearAllMessages,
            isDestructive: true,
          ),
          const Divider(height: 1, indent: AppSpacing.xl + AppSpacing.xl + AppSpacing.md),
          _buildActionTile(
            icon: CupertinoIcons.trash,
            title: 'Supprimer toutes les discussions',
            subtitle: 'Supprime définitivement conversations et messages',
            onTap: _deleteAll,
            isDestructive: true,
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    final color = isDestructive ? context.colors.error : context.colors.onSurfaceVariant;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl, vertical: AppSpacing.sm),
      leading: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: isDestructive
              ? AppColors.errorContainer
              : context.semantic.surfaceMuted,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: AppIconSize.md),
      ),
      title: Text(
        title,
        style: context.text.bodyLarge?.copyWith(
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            )
          : null,
      onTap: onTap,
    );
  }
}
