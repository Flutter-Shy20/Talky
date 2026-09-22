import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' show PlayerState;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../../core/errors/afficher_erreur.dart';
import '../../core/errors/app_error.dart';
import '../../core/services/call/voicemail_greeting_player.dart';
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
  bool didRing = false,
}) {
  return showAppBottomSheet<void>(
    context: context,
    builder: (_) => _VoicemailRecorderSheet(
      peerName: peerName,
      peerUserId: peerUserId,
      conversationID: conversationID,
      didRing: didRing,
    ),
  );
}

class _VoicemailRecorderSheet extends StatefulWidget {
  const _VoicemailRecorderSheet({
    required this.peerName,
    required this.peerUserId,
    this.conversationID,
    this.didRing = false,
  });

  final String peerName;
  final int peerUserId;
  final int? conversationID;

  /// Le téléphone d'en face a-t-il sonné ? Change les mots, pas le mécanisme.
  final bool didRing;

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

  /// Vrai dès qu'on sait s'il y a une annonce à jouer ou non.
  bool _annonceResolue = false;
  bool _aUneAnnonce = false;
  StreamSubscription<PlayerState>? _abonnementLecture;

  @override
  void initState() {
    super.initState();
    // L'annonce se lance toute seule, et NE BLOQUE RIEN : le bouton
    // d'enregistrement est actif dès maintenant. Si le réseau traîne ou si
    // l'annonce n'arrive jamais, l'appelant parle quand même.
    unawaited(_preparerAnnonce());
  }

  Future<void> _preparerAnnonce() async {
    final lecteur = VoicemailGreetingPlayer.instance;
    final chemin = await lecteur.whenReady();
    if (!mounted) return;
    setState(() {
      _annonceResolue = true;
      _aUneAnnonce = chemin != null;
    });
    if (chemin == null) return;

    _abonnementLecture = lecteur.stateStream?.listen((_) {
      if (mounted) setState(() {});
    });
    await lecteur.play();
    if (!mounted) return;
    // Le flux n'existe qu'une fois le lecteur construit, d'où ce second essai.
    _abonnementLecture ??= lecteur.stateStream?.listen((_) {
      if (mounted) setState(() {});
    });
    setState(() {});
  }

  /// Bascule lecture/pause de l'annonce, et la rejoue si elle est terminée.
  Future<void> _basculerAnnonce() async {
    final lecteur = VoicemailGreetingPlayer.instance;
    if (lecteur.isPlaying) {
      await lecteur.pause();
    } else {
      await lecteur.resume();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _abonnementLecture?.cancel();
    // Le son ne doit pas survivre à l'écran.
    unawaited(VoicemailGreetingPlayer.instance.release());
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
    // La permission micro est normalement déjà acquise : on vient de tenter un
    // appel, et `CallPermissionsHelper.ensureCallMediaPermissions` l'exige.
    //
    // Mais « normalement » ne suffit pas, et sortir en silence sur un refus
    // était une faute : l'utilisateur appuyait sur « Enregistrer », rien ne se
    // passait, et rien ne lui disait pourquoi. Le chat et les statuts font la
    // même chose — c'est un défaut que je ne reproduis pas ici.
    if (!await _recorder.hasPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.microphonePermissionDenied2)),
      );
      return;
    }
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
            widget.didRing
                ? l10n.voicemailPeerNoAnswer(widget.peerName)
                : l10n.voicemailPeerUnavailable(widget.peerName),
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
          // L'annonce, quand il y en a une. Elle se joue déjà ; ce contrôle
          // sert à la couper ou à la réécouter, pas à la démarrer.
          if (_annonceResolue && _aUneAnnonce && !_isRecording) ...[
            AppSpacing.vGapMd,
            TextButton.icon(
              onPressed: _basculerAnnonce,
              icon: Icon(
                VoicemailGreetingPlayer.instance.isPlaying
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
              ),
              label: Text(
                VoicemailGreetingPlayer.instance.isPlaying
                    ? l10n.voicemailGreetingPause
                    : l10n.voicemailGreetingReplay,
              ),
            ),
          ],
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
          // Empilés, jamais côte à côte.
          //
          // Un `Row` de deux boutons « icône + libellé » tient à l'échelle de
          // texte par défaut, et déborde dès qu'elle grandit — or `fontScale`
          // est un réglage de l'application, appliqué globalement dans
          // `main.dart`. Le débordement ne prévient pas : Flutter rogne la
          // droite, et c'est « Envoyer » qui disparaît. L'utilisateur se
          // retrouve devant un enregistrement qu'il ne peut qu'annuler.
          //
          // En colonne, largeur pleine, la mise en page tient à toutes les
          // échelles, et l'action principale tombe sous le pouce.
          else if (_isRecording)
            Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _stop(send: true),
                    icon: const Icon(Icons.send_rounded),
                    label: Text(l10n.voicemailSend),
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
