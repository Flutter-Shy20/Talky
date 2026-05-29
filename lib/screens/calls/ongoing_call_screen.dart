import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../../core/services/call_service.dart';

/// Écran d'appel en cours (1-à-1, audio ou vidéo).
///
/// Trois sous-états gérés par le même widget :
/// - `connecting`  : "Connexion..." + spinner + ringback (déjà géré par CallService)
/// - `connected`   : timer + flux audio/vidéo
/// - `ended`/`idle`: pop automatique
class OngoingCallScreen extends StatefulWidget {
  const OngoingCallScreen({super.key});

  @override
  State<OngoingCallScreen> createState() => _OngoingCallScreenState();
}

class _OngoingCallScreenState extends State<OngoingCallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  static const Size _pipSize = Size(110, 160);
  static const double _pipMargin = 16;
  bool _renderersReady = false;
  bool _closing = false;
  Offset? _pipOffset;
  bool _showLocalVideoAsMain = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    _initRenderers();
  }

  void _snapPipToEdge(Size screenSize, EdgeInsets padding) {
    final current = _pipOffset ?? _defaultPipOffset(screenSize, padding);

    final snapLeft =
        current.dx < screenSize.width / 2;

    final targetX = snapLeft
        ? _pipMargin
        : screenSize.width - _pipSize.width - _pipMargin;

    setState(() {
      _pipOffset = Offset(current.dy.isNaN ? 0 : targetX, current.dy);
    });
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (!mounted) return;

    final cs = Provider.of<CallService>(context, listen: false);

    // ✅ FIX: Assigner les streams immédiatement s'ils existent
    debugPrint('[OngoingCall] 📹 Init renderers');
    debugPrint(
      '[OngoingCall] Local stream: ${cs.localStream != null ? "✅" : "❌"}',
    );
    debugPrint(
      '[OngoingCall] Remote stream: ${cs.remoteStream != null ? "✅" : "❌"}',
    );

    _localRenderer.srcObject = cs.localStream;
    _remoteRenderer.srcObject = cs.remoteStream;

    // ✅ S'abonner aux changements de CallService
    cs.addListener(_onCallChanged);

    setState(() => _renderersReady = true);
  }

  void _onCallChanged() {
    if (_closing || !mounted) return;
    final cs = Provider.of<CallService>(context, listen: false);

    debugPrint(
      '[OngoingCall] 📹 State changed: status=${cs.status}, local=${cs.localStream != null ? "✅" : "❌"}, remote=${cs.remoteStream != null ? "✅" : "❌"}',
    );

    // ✅ FIX CRITIQUE: TOUJOURS mettre à jour les renderers
    // Ne pas vérifier si ça a "changé" - juste le faire
    // Parfois le stream arrive après le premier call, ou est réassigné
    setState(() {
      if (_renderersReady) {
        final localChanged = _localRenderer.srcObject != cs.localStream;
        final remoteChanged = _remoteRenderer.srcObject != cs.remoteStream;

        if (localChanged) {
          debugPrint(
            '[OngoingCall] 📹 Update local renderer: ${cs.localStream != null ? "stream" : "null"}',
          );
          _localRenderer.srcObject = cs.localStream;
        }
        if (remoteChanged) {
          debugPrint(
            '[OngoingCall] 📹 Update remote renderer: ${cs.remoteStream != null ? "stream" : "null"}',
          );
          _remoteRenderer.srcObject = cs.remoteStream;
        }
      }
    });

    if (cs.status == CallStatus.ended && !cs.callEndedByUs) {
      debugPrint('[OngoingCall] 📞 Appel terminé par l\'autre côté');
      _closeAndPop();
      return;
    }
    if (cs.status == CallStatus.idle) {
      debugPrint('[OngoingCall] 📞 Statut idle, fermeture');
      _closeAndPop();
      return;
    }
  }

  void _closeAndPop() {
    if (_closing) return;
    _closing = true;
    final cs = Provider.of<CallService>(context, listen: false);
    cs.removeListener(_onCallChanged);
    if (_renderersReady) {
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _hangUp() async {
    if (_closing) return;
    _closing = true;
    final cs = Provider.of<CallService>(context, listen: false);
    cs.removeListener(_onCallChanged);
    if (_renderersReady) {
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;
    }
    await cs.endCall();
    if (mounted) Navigator.of(context).maybePop();
  }

  Offset _defaultPipOffset(Size screenSize, EdgeInsets padding) {
    return Offset(
      screenSize.width - _pipSize.width - _pipMargin,
      padding.top + 12,
    );
  }

  Offset _clampPipOffset(Offset offset, Size screenSize, EdgeInsets padding) {
    final minX = _pipMargin;
    final maxX = screenSize.width - _pipSize.width - _pipMargin;
    final minY = padding.top + 12;
    final maxY = screenSize.height - _pipSize.height - padding.bottom - 112;

    return Offset(
      offset.dx.clamp(minX, maxX < minX ? minX : maxX).toDouble(),
      offset.dy.clamp(minY, maxY < minY ? minY : maxY).toDouble(),
    );
  }

  void _movePip(
    DragUpdateDetails details,
    Size screenSize,
    EdgeInsets padding,
  ) {
    setState(() {
      final current = _pipOffset ?? _defaultPipOffset(screenSize, padding);
      _pipOffset = _clampPipOffset(
        current + details.delta,
        screenSize,
        padding,
      );
    });
  }

  void _toggleVideoSwap() {
    setState(() => _showLocalVideoAsMain = !_showLocalVideoAsMain);
  }

  @override
  void dispose() {
    try {
      Provider.of<CallService>(
        context,
        listen: false,
      ).removeListener(_onCallChanged);
    } catch (_) {}
    if (_renderersReady) {
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;
      _localRenderer.dispose();
      _remoteRenderer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CallService>(
      builder: (_, cs, __) {
        final isVideo = cs.isVideo;
        final hasRemoteVideo = isVideo && _remoteRenderer.srcObject != null;
        final hasLocalVideo =
            isVideo && _renderersReady && _localRenderer.srcObject != null;
        final showLocalVideoAsMain = _showLocalVideoAsMain && hasLocalVideo;
        final pipRenderer = showLocalVideoAsMain
            ? _remoteRenderer
            : _localRenderer;
        final hasPipVideo = showLocalVideoAsMain
            ? hasRemoteVideo
            : hasLocalVideo;
        final padding = MediaQuery.of(context).padding;
        final screenSize = MediaQuery.of(context).size;
        final pipOffset = _clampPipOffset(
          _pipOffset ?? _defaultPipOffset(screenSize, padding),
          screenSize,
          padding,
        );
        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              // Background : remote video plein écran si vidéo, sinon gradient + avatar
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: child,
                  );
                },
                child: showLocalVideoAsMain
                    ? Container(
                  key: const ValueKey('local_fullscreen'),
                  color: Colors.black,
                  child: RTCVideoView(
                    _localRenderer,
                    mirror: true,
                    objectFit:
                    RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                )
                    : hasRemoteVideo
                    ? Container(
                  key: const ValueKey('remote_fullscreen'),
                  color: Colors.black,
                  child: RTCVideoView(
                    _remoteRenderer,
                    objectFit:
                    RTCVideoViewObjectFit
                        .RTCVideoViewObjectFitCover,
                  ),
                )
                    : Container(
                  key: const ValueKey('audio_backdrop'),
                  child: _AudioBackdrop(
                    name: cs.remoteUserName ?? 'Inconnu',
                    photoUrl: cs.remoteUserPhoto,
                  ),
                ),
              ),

              // Local video PiP (vidéo uniquement)
              if (hasPipVideo)
                Positioned(
                  left: pipOffset.dx,
                  top: pipOffset.dy,
                  child: _LocalPiP(
                    renderer: pipRenderer,
                    mirror: !showLocalVideoAsMain,
                    onTap: _toggleVideoSwap,
                    onPanUpdate: (details) =>
                        _movePip(details, screenSize, padding),

                    onPanEnd: () =>
                        _snapPipToEdge(screenSize, padding),
                  ),
                ),

              // Top bar : nom + statut + chronomètre
              Positioned(
                left: 0,
                right: 0,
                top: padding.top,
                child: _TopBar(
                  name: cs.remoteUserName ?? 'Appel',
                  status: _statusLabel(cs),
                  duration: cs.status == CallStatus.connected
                      ? cs.formattedDuration
                      : null,
                  onMinimize: () => Navigator.of(context).maybePop(),
                ),
              ),

              // Bottom controls
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _BottomControls(
                  isVideo: isVideo,
                  isMuted: cs.isMuted,
                  isVideoOn: cs.isVideoOn,
                  isSpeakerOn: cs.isSpeakerOn,
                  onMute: () => cs.toggleMute(),
                  onSpeaker: () => cs.toggleSpeaker(),
                  onCamera: () => cs.toggleCamera(),
                  onSwitchCam: () => cs.switchCamera(),
                  onHangUp: _hangUp,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _statusLabel(CallService cs) {
    switch (cs.status) {
      case CallStatus.outgoing:
      case CallStatus.connecting:
        return 'Connexion…';
      case CallStatus.connected:
        return 'En cours';
      case CallStatus.ended:
        return 'Terminé';
      default:
        return '';
    }
  }
}

// ─── Sous-widgets ──────────────────────────────────────────────────────

class _AudioBackdrop extends StatelessWidget {
  const _AudioBackdrop({required this.name, required this.photoUrl});

  final String name;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    final url = photoUrl;
    final hasPhoto =
        url != null &&
        url.isNotEmpty &&
        url.toUpperCase() != 'NON DEFINI' &&
        (url.startsWith('http://') || url.startsWith('https://'));
    final initial = name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?';
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A237E), Color(0xFF000000)],
        ),
      ),
      alignment: Alignment.center,
      child: CircleAvatar(
        radius: 90,
        backgroundColor: const Color(0xFF3949AB),
        backgroundImage: hasPhoto ? NetworkImage(url) : null,
        child: hasPhoto
            ? null
            : Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 64,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}

class _LocalPiP extends StatefulWidget {
  const _LocalPiP({
    required this.renderer,
    required this.mirror,
    required this.onTap,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  final RTCVideoRenderer renderer;
  final bool mirror;
  final VoidCallback onTap;
  final GestureDragUpdateCallback onPanUpdate;
  final VoidCallback onPanEnd;

  @override
  State<_LocalPiP> createState() => _LocalPiPState();
}

class _LocalPiPState extends State<_LocalPiP> {
  bool _wasDragged = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (!_wasDragged) {
          widget.onTap();
        }

        _wasDragged = false;
      },

      onPanUpdate: (details) {
        _wasDragged = true;
        widget.onPanUpdate(details);
      },

      onPanEnd: (_) {
        widget.onPanEnd();

        Future.delayed(
          const Duration(milliseconds: 80),
              () {
            _wasDragged = false;
          },
        );
      },

      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: _OngoingCallScreenState._pipSize.width,
        height: _OngoingCallScreenState._pipSize.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.28),
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 14,
              offset: Offset(0, 5),
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: RTCVideoView(
          widget.renderer,
          mirror: widget.mirror,
          objectFit:
          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.name,
    required this.status,
    required this.duration,
    required this.onMinimize,
  });

  final String name;
  final String status;
  final String? duration;
  final VoidCallback onMinimize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(
              CupertinoIcons.chevron_down,
              color: Colors.white,
              size: 28,
            ),
            onPressed: onMinimize,
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  duration ?? status,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _BottomControls extends StatelessWidget {
  const _BottomControls({
    required this.isVideo,
    required this.isMuted,
    required this.isVideoOn,
    required this.isSpeakerOn,
    required this.onMute,
    required this.onSpeaker,
    required this.onCamera,
    required this.onSwitchCam,
    required this.onHangUp,
  });

  final bool isVideo;
  final bool isMuted;
  final bool isVideoOn;
  final bool isSpeakerOn;
  final VoidCallback onMute;
  final VoidCallback onSpeaker;
  final VoidCallback onCamera;
  final VoidCallback onSwitchCam;
  final VoidCallback onHangUp;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        24,
        20,
        24 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _RoundButton(
            icon: isMuted ? CupertinoIcons.mic_off : CupertinoIcons.mic_solid,
            active: isMuted,
            onTap: onMute,
          ),
          if (isVideo)
            _RoundButton(
              icon: isVideoOn ? Icons.videocam : Icons.videocam_off,
              active: !isVideoOn,
              onTap: onCamera,
            )
          else
            _RoundButton(
              icon: isSpeakerOn
                  ? CupertinoIcons.speaker_3_fill
                  : CupertinoIcons.speaker_2,
              active: isSpeakerOn,
              onTap: onSpeaker,
            ),
          if (isVideo)
            _RoundButton(
              icon: CupertinoIcons.switch_camera,
              active: false,
              onTap: onSwitchCam,
            ),
          _HangUpButton(onTap: onHangUp),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.white.withValues(alpha: 0.18),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
        ),
        child: Icon(
          icon,
          color: active ? Colors.black : Colors.white,
          size: 26,
        ),
      ),
    );
  }
}

class _HangUpButton extends StatelessWidget {
  const _HangUpButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 68,
        height: 68,
        decoration: const BoxDecoration(
          color: Color(0xFFE53935),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: const Icon(
          CupertinoIcons.phone_down_fill,
          color: Colors.white,
          size: 30,
        ),
      ),
    );
  }
}
