import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../../core/errors/afficher_erreur.dart';
import '../../core/errors/app_error.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/chat_provider.dart';
import '../../talky_api_client.dart';
import '../common/app_bottom_sheet.dart';

/// Feuille « laisser un message », ouverte quand un appel tombe sur le
/// répondeur du correspondant.
///
/// Elle s'ouvre APRÈS `_terminateCall()`, jamais avant, et ce n'est pas un
/// détail d'ordonnancement : l'appel sortant a acquis le micro et basculé
/// `audio_session` en catégorie `call` avant même d'émettre `call_user`. Lancer
/// l'enregistreur sans avoir relâché cette session donne un fichier en bande
/// téléphonique sur Android, et rien du tout sur iOS.
///
/// Le message part comme un message vocal ORDINAIRE (type 3) dans la
/// conversation directe : tout le pipeline existant — mise en attente hors
/// ligne, envoi, forme d'onde, lecture, notification — s'applique sans une
/// ligne de plus. Aucun marqueur ne le distingue : l'entrée « Répondeur » du
/// journal d'appels porte déjà le même horodatage, et un marqueur dans
/// `content` fuiterait en clair dans les aperçus des versions plus anciennes
/// de l'application.
Future<void> showVoicemailRecorder({
  required BuildContext context,
  required String peerName,
  required int peerUserId,
  int? conversationID,
}) {
  return showAppBottomSheet<void>(
    context: context,
    builder: (_) => _VoicemailRecorderSheet(
      peerName: peerName,
      peerUserId: peerUserId,
      conversationID: conversationID,
    ),
  );
}

class _VoicemailRecorderSheet extends StatefulWidget {
  const _VoicemailRecorderSheet({
    required this.peerName,
    required this.peerUserId,
    this.conversationID,
  });

  final String peerName;
  final int peerUserId;
  final int? conversationID;

  @override
  State<_VoicemailRecorderSheet> createState() =>
      _VoicemailRecorderSheetState();
}

class _VoicemailRecorderSheetState extends State<_VoicemailRecorderSheet> {
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  bool _sending = false;
  int _seconds = 0;
  Timer? _timer;

  /// Même seuil que le chat et les statuts : en dessous d'une seconde, c'est
  /// une fausse manœuvre, pas un message.
  static const int _minSeconds = 1;

  @override
  void dispose() {
    _timer?.cancel();
    // Un enregistrement encore en cours quand la feuille se ferme : on coupe et
    // on jette. Laisser le micro ouvert bloquerait l'appel suivant.
    unawaited(_recorder.stop().then((p) => _supprimer(p)));
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
    // La permission micro est déjà acquise : on vient de tenter un appel, et
    // `CallPermissionsHelper.ensureCallMediaPermissions` l'exige. Le test reste
    // au cas où elle aurait été révoquée entre-temps.
    if (!await _recorder.hasPermission()) return;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voicemail_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path);
    if (!mounted) return;
    setState(() {
      _isRecording = true;
      _seconds = 0;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds += 1);
    });
  }

  Future<void> _stop({required bool send}) async {
    _timer?.cancel();
    final path = await _recorder.stop();
    final seconds = _seconds;
    if (mounted) setState(() => _isRecording = false);

    if (!send || path == null || seconds < _minSeconds) {
      _supprimer(path);
      if (send && mounted) Navigator.of(context).pop();
      return;
    }
    await _envoyer(File(path), seconds);
  }

  Future<void> _envoyer(File file, int seconds) async {
    setState(() => _sending = true);
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final chat = context.read<ChatProvider>();
      // Le serveur a déjà résolu la conversation et l'a transmise dans
      // `call_voicemail` : un aller-retour de moins avant l'envoi. Le repli
      // couvre le cas où il n'aurait pas pu la créer.
      var convId = widget.conversationID;
      if (convId == null) {
        final api = context.read<TalkyApiClient>();
        final result =
            await api.createConversation(participantID: widget.peerUserId);
        convId = result['conversID'] as int?;
      }
      if (convId == null) throw StateError('conversID manquant');

      await chat.repository.sendMediaFile(
        conversationID: convId,
        type: 3,
        file: file,
        mediaName: l10n.voiceMessage,
        mediaDuration: seconds,
      );

      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.voicemailSent),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      // Le passage obligé : il traduit, journalise, et n'affiche jamais
      // l'exception brute.
      afficherErreur(context, e, domaine: ErrorDomain.appel);
    }
  }

  String _chrono(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.colors;

    return AppBottomSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: context.semantic.surfaceMuted,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.voicemail_rounded,
                size: AppIconSize.lg, color: colors.primary),
          ),
          AppSpacing.vGapLg,
          Text(
            l10n.voicemailPeerUnavailable(widget.peerName),
            style: context.text.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          AppSpacing.vGapSm,
          Text(
            l10n.voicemailLeaveMessage,
            style: context.text.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          AppSpacing.vGapXl,
          if (_isRecording)
            Text(
              _chrono(_seconds),
              style: context.text.headlineSmall?.copyWith(
                color: colors.error,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          if (_isRecording) AppSpacing.vGapLg,
          if (_sending)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: CircularProgressIndicator(),
            )
          else if (_isRecording)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton.icon(
                  onPressed: () => _stop(send: false),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l10n.voicemailDiscard),
                  style: TextButton.styleFrom(foregroundColor: colors.error),
                ),
                FilledButton.icon(
                  onPressed: () => _stop(send: true),
                  icon: const Icon(Icons.send_rounded),
                  label: Text(l10n.voicemailSend),
                ),
              ],
            )
          else
            Column(
              children: [
                FilledButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.mic_rounded),
                  label: Text(l10n.voicemailRecord),
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
