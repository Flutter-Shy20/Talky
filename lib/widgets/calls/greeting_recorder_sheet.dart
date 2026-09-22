import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../../core/errors/afficher_erreur.dart';
import '../../core/errors/app_error.dart';
import '../../core/services/call/voicemail_provider.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../common/app_bottom_sheet.dart';

/// Durée maximale de l'annonce. « Quelques secondes », pas un monologue.
const int kMaxGreetingSeconds = 10;

/// Encodage bridé, et c'est voulu.
///
/// Les quatre autres enregistreurs du dépôt utilisent `RecordConfig` nu, donc
/// le débit par défaut. Ici le fichier sera téléchargé par CHAQUE appelant au
/// moment précis où il attend — dix secondes en mono à 32 kbit/s font une
/// quarantaine de kilooctets, contre plusieurs centaines autrement. La qualité
/// suffit largement pour une voix.
const RecordConfig kGreetingRecordConfig = RecordConfig(
  encoder: AudioEncoder.aacLc,
  bitRate: 32000,
  numChannels: 1,
  sampleRate: 22050,
);

/// Enregistrer ou remplacer l'annonce vocale de son répondeur.
Future<void> showGreetingRecorder(BuildContext context) {
  return showAppBottomSheet<void>(
    context: context,
    builder: (_) => const _GreetingRecorderSheet(),
  );
}

class _GreetingRecorderSheet extends StatefulWidget {
  const _GreetingRecorderSheet();

  @override
  State<_GreetingRecorderSheet> createState() => _GreetingRecorderSheetState();
}

class _GreetingRecorderSheetState extends State<_GreetingRecorderSheet> {
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  bool _sending = false;
  int _seconds = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_recorder.stop().then(_supprimer));
    _recorder.dispose();
    super.dispose();
  }

  void _supprimer(String? path) {
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // Un temporaire qui survit est sans conséquence : le système le purge.
    }
  }

  Future<void> _start() async {
    if (!await _recorder.hasPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.microphonePermissionDenied2)),
      );
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/greeting_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(kGreetingRecordConfig, path: path);
    if (!mounted) return;
    setState(() {
      _isRecording = true;
      _seconds = 0;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds += 1);
      // Le plafond s'applique tout seul. Laisser l'utilisateur dépasser pour
      // se faire refuser ensuite par le serveur serait lui faire perdre son
      // enregistrement.
      if (_seconds >= kMaxGreetingSeconds) unawaited(_stop(send: true));
    });
  }

  Future<void> _stop({required bool send}) async {
    if (!_isRecording) return;
    _timer?.cancel();
    final path = await _recorder.stop();
    final seconds = _seconds;
    if (mounted) setState(() => _isRecording = false);

    if (!send || path == null || seconds < 1) {
      _supprimer(path);
      return;
    }
    await _envoyer(File(path), seconds);
  }

  Future<void> _envoyer(File file, int seconds) async {
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      await context.read<VoicemailProvider>().uploadGreeting(file, seconds);
      _supprimer(file.path);
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.voicemailGreetingSaved),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      afficherErreur(context, e, domaine: ErrorDomain.appel);
    }
  }

  String _chrono(int s) => '00:${s.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.colors;

    return AppBottomSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.voicemailGreetingTitle,
            style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          AppSpacing.vGapSm,
          Text(
            l10n.voicemailGreetingHint(kMaxGreetingSeconds),
            style: context.text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          AppSpacing.vGapXl,
          Text(
            _chrono(_seconds),
            style: context.text.headlineSmall?.copyWith(
              color: _isRecording ? colors.error : colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          AppSpacing.vGapLg,
          if (_sending)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: CircularProgressIndicator(),
            )
          else if (_isRecording)
            Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _stop(send: true),
                    icon: const Icon(Icons.stop_rounded),
                    label: Text(l10n.voicemailGreetingStop),
                  ),
                ),
                AppSpacing.vGapSm,
                TextButton.icon(
                  onPressed: () => _stop(send: false),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l10n.voicemailDiscard),
                  style: TextButton.styleFrom(foregroundColor: colors.error),
                ),
              ],
            )
          else
            Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.mic_rounded),
                    label: Text(l10n.voicemailRecord),
                  ),
                ),
                AppSpacing.vGapSm,
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.voicemailNotNow),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
