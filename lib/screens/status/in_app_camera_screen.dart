import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';

/// Caméra intégrée — ne quitte jamais l'app Flutter.
/// Retourne un [File] via [Navigator.pop] ou null si annulé.
class InAppCameraScreen extends StatefulWidget {
  const InAppCameraScreen({super.key, this.forVideo = false});

  final bool forVideo;

  @override
  State<InAppCameraScreen> createState() => _InAppCameraScreenState();
}

class _InAppCameraScreenState extends State<InAppCameraScreen>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = [];
  CameraController? _controller;
  int _cameraIndex = 0;
  bool _initializing = true;
  bool _capturing = false;
  File? _preview;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _initCameras();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller = null;
      ctrl.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera(_cameras[_cameraIndex]);
    }
  }

  Future<void> _initCameras() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) Navigator.pop(context);
        return;
      }
      // Préférer la caméra arrière par défaut
      _cameraIndex = _cameras.indexWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
          );
      if (_cameraIndex < 0) _cameraIndex = 0;
      await _initCamera(_cameras[_cameraIndex]);
    } catch (_) {
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _initCamera(CameraDescription desc) async {
    final prev = _controller;
    if (prev != null) {
      await prev.dispose();
      _controller = null;
    }
    final ctrl = CameraController(
      desc,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _controller = ctrl;
    try {
      await ctrl.initialize();
      if (!mounted) return;
      setState(() => _initializing = false);
    } catch (_) {
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    setState(() => _initializing = true);
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _initCamera(_cameras[_cameraIndex]);
  }

  Future<void> _capture() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    try {
      final xfile = await ctrl.takePicture();
      final dir = await getTemporaryDirectory();
      final dest = '${dir.path}/cam_${DateTime.now().millisecondsSinceEpoch}.jpg';
      // Compresse la photo comme image_picker (qualité 80, max 1920px)
      // pour éviter le rejet nginx 413 sur les photos pleine résolution.
      final result = await FlutterImageCompress.compressAndGetFile(
        xfile.path,
        dest,
        quality: 80,
        minWidth: 1920,
        minHeight: 1080,
        keepExif: false,
      );
      final file = File(result?.path ?? xfile.path);
      if (mounted) setState(() => _preview = file);
    } catch (_) {
      if (mounted) setState(() => _capturing = false);
    }
  }

  void _confirm() {
    if (_preview != null) Navigator.pop(context, _preview);
  }

  void _retake() {
    setState(() {
      _preview = null;
      _capturing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.black,
      body: _preview != null ? _buildPreview() : _buildViewfinder(),
    );
  }

  // ── Viseur ──────────────────────────────────────────────────────────────

  Widget _buildViewfinder() {
    final ctrl = _controller;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (!_initializing && ctrl != null && ctrl.value.isInitialized)
          Center(child: CameraPreview(ctrl))
        else
          const Center(child: CircularProgressIndicator(color: Colors.white)),

        // Fermer
        Positioned(
          top: MediaQuery.of(context).padding.top + AppSpacing.sm,
          left: AppSpacing.md,
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 28),
            onPressed: () => Navigator.pop(context),
          ),
        ),

        // Retourner caméra
        if (_cameras.length > 1)
          Positioned(
            top: MediaQuery.of(context).padding.top + AppSpacing.sm,
            right: AppSpacing.md,
            child: IconButton(
              icon: const Icon(Icons.flip_camera_ios_outlined,
                  color: Colors.white, size: 28),
              onPressed: _initializing ? null : _switchCamera,
            ),
          ),

        // Bouton déclencheur
        Positioned(
          bottom: MediaQuery.of(context).padding.bottom + AppSpacing.xxl,
          left: 0,
          right: 0,
          child: Center(
            child: GestureDetector(
              onTap: _capture,
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 4),
                ),
                child: _capturing
                    ? const Padding(
                        padding: EdgeInsets.all(18),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Container(
                        margin: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Prévisualisation après capture ──────────────────────────────────────

  Widget _buildPreview() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(_preview!, fit: BoxFit.cover),

        // Reprendre
        Positioned(
          bottom: MediaQuery.of(context).padding.bottom + AppSpacing.xxl,
          left: AppSpacing.xxl,
          child: _ActionButton(
            icon: Icons.refresh_rounded,
            label: 'Reprendre',
            onTap: _retake,
          ),
        ),

        // Utiliser
        Positioned(
          bottom: MediaQuery.of(context).padding.bottom + AppSpacing.xxl,
          right: AppSpacing.xxl,
          child: _ActionButton(
            icon: Icons.check_rounded,
            label: 'Utiliser',
            filled: true,
            onTap: _confirm,
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: filled ? AppColors.brandPrimary : Colors.black54,
          borderRadius: AppRadius.brPill,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: AppIconSize.sm),
            const SizedBox(width: AppSpacing.sm),
            Text(label,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
