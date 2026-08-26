import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/app_log.dart';
import '../../talky_api_client.dart';
import '../common/app_bottom_sheet.dart';

/// Motifs de signalement. Les clés sont celles que le serveur accepte
/// (`REPORT_REASONS` dans `reportService.js`) ; l'ordre est celui de l'écran,
/// du plus fréquemment invoqué au plus rare.
const List<String> kReportReasons = [
  'harassment',
  'hate',
  'violence',
  'sexual',
  'scam',
  'spam',
  'impersonation',
  'other',
];

const int kReportNoteMax = 500;

IconData _reasonIcon(String reason) => switch (reason) {
      'harassment' => Icons.sentiment_very_dissatisfied_outlined,
      'hate' => Icons.report_gmailerrorred_outlined,
      'violence' => Icons.warning_amber_outlined,
      'sexual' => Icons.no_adult_content_outlined,
      'scam' => Icons.money_off_outlined,
      'spam' => Icons.repeat_outlined,
      'impersonation' => Icons.person_off_outlined,
      _ => Icons.more_horiz,
    };

String _reasonLabel(BuildContext context, String reason) {
  final l10n = context.l10n;
  return switch (reason) {
    'harassment' => l10n.reportReasonHarassment,
    'hate' => l10n.reportReasonHate,
    'violence' => l10n.reportReasonViolence,
    'sexual' => l10n.reportReasonSexual,
    'scam' => l10n.reportReasonScam,
    'spam' => l10n.reportReasonSpam,
    'impersonation' => l10n.reportReasonImpersonation,
    _ => l10n.reportReasonOther,
  };
}

/// Ouvre la feuille de signalement.
///
/// [targetType] vaut `message` ou `user`. Le retour indique si un signalement
/// a bien été transmis — l'appelant s'en sert pour son propre retour visuel.
Future<bool> showReportSheet(
  BuildContext context, {
  required String targetType,
  required int targetId,
}) async {
  final sent = await showAppBottomSheet<bool>(
    context: context,
    builder: (_) => _ReportSheet(targetType: targetType, targetId: targetId),
  );
  return sent ?? false;
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.targetType, required this.targetId});

  final String targetType;
  final int targetId;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final TextEditingController _note = TextEditingController();
  String? _reason;
  bool _sending = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null || _sending) return;
    setState(() => _sending = true);

    final api = Provider.of<TalkyApiClient>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      await api.sendReport(
        targetType: widget.targetType,
        targetId: widget.targetId,
        reason: reason,
        note: _note.text,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
      // Le message de succès ne distingue pas un doublon d'un premier envoi :
      // la plainte est enregistrée dans les deux cas, et dire « déjà signalé »
      // laisserait croire qu'il fallait faire autre chose.
      messenger.showSnackBar(SnackBar(content: Text(l10n.reportSent)));
    } catch (e, st) {
      AppLog.e('ReportSheet', 'Envoi du signalement échoué', e, st);
      if (!mounted) return;
      setState(() => _sending = false);
      messenger.showSnackBar(SnackBar(content: Text(l10n.reportFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.colors;
    final muted = colors.onSurfaceVariant;

    return AppBottomSheet(
      // Le clavier ne doit pas recouvrir le champ de précision.
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.targetType == 'message'
                  ? l10n.reportMessageTitle
                  : l10n.reportUserTitle,
              style: context.text.titleMedium,
            ),
            AppSpacing.vGapXs,
            Text(l10n.reportSubtitle, style: context.text.bodySmall?.copyWith(color: muted)),
            AppSpacing.vGapMd,

            for (final reason in kReportReasons)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                enabled: !_sending,
                leading: Icon(
                  _reasonIcon(reason),
                  size: 20,
                  color: _reason == reason ? colors.primary : muted,
                ),
                title: Text(_reasonLabel(context, reason)),
                trailing: _reason == reason
                    ? Icon(Icons.check, size: 18, color: colors.primary)
                    : null,
                onTap: () => setState(() => _reason = reason),
              ),

            AppSpacing.vGapSm,
            TextField(
              controller: _note,
              enabled: !_sending,
              maxLength: kReportNoteMax,
              maxLines: 3,
              minLines: 1,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: l10n.reportNoteHint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            AppSpacing.vGapSm,
            FilledButton(
              onPressed: _reason == null || _sending ? null : _submit,
              child: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.reportSubmit),
            ),
          ],
        ),
      ),
    );
  }
}
