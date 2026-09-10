import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/errors/afficher_erreur.dart';
import '../../core/errors/app_error.dart';
import '../../core/errors/error_presenter.dart';
import '../../core/services/billing/entitlement_service.dart';
import '../../core/services/billing/verification_models.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../talky_api_client.dart';
import '../../widgets/billing/plus_visuals.dart';
import '../../widgets/common/account_badge.dart' show VerifiedSeal;
import '../../widgets/common/app_bottom_sheet.dart';

/// « Obtenir la coche » : la pièce et le selfie, l'examen, puis la coche.
///
/// Une seule demande ouverte à la fois. L'écran dit avant l'envoi ce que
/// deviennent les pièces — chiffrées, vues par l'administration seule,
/// détruites 90 jours après la décision — et, pendant l'examen, une fourchette
/// de délai plutôt qu'un compte à rebours.
class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key});

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

enum _Slot { front, back, selfie }

class _VerificationScreenState extends State<VerificationScreen> {
  VerificationState? _state;
  Object? _error;
  bool _busy = false;
  final Map<_Slot, File> _pieces = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final raw = await context.read<TalkyApiClient>().getVerification();
      if (!mounted) return;
      setState(() {
        _state = VerificationState.fromJson(raw);
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _apply(Map<String, dynamic> raw) {
    setState(() {
      _state = VerificationState.fromJson(raw);
      _pieces.clear();
    });
    // La coche voyage avec les droits : le profil et la carte suivent.
    final droits = EntitlementService.maybeInstance;
    if (droits != null) unawaited(droits.refresh());
  }

  Future<void> _pick(_Slot slot) async {
    final l10n = context.l10n;
    final source = await showAppBottomSheet<ImageSource>(
      context: context,
      builder: (sheet) => AppBottomSheet(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(l10n.verificationTakePhoto),
              onTap: () => Navigator.pop(sheet, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(l10n.verificationChooseGallery),
              onTap: () => Navigator.pop(sheet, ImageSource.gallery),
            ),
            if (_pieces[slot] != null)
              ListTile(
                leading: Icon(Icons.delete_outline, color: context.colors.error),
                title: Text(l10n.verificationRemove,
                    style: TextStyle(color: context.colors.error)),
                onTap: () {
                  Navigator.pop(sheet);
                  setState(() => _pieces.remove(slot));
                },
              ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    final picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 2200,
      // Le selfie se prend face à l'utilisateur, la pièce avec l'autre caméra.
      preferredCameraDevice:
          slot == _Slot.selfie ? CameraDevice.front : CameraDevice.rear,
    );
    if (picked == null || !mounted) return;
    setState(() => _pieces[slot] = File(picked.path));
  }

  Future<void> _send() async {
    final state = _state;
    if (state == null || _busy) return;
    final completing =
        state.request?.status == VerificationRequestStatus.documentRequested;
    setState(() => _busy = true);
    final api = context.read<TalkyApiClient>();
    final identity = [_pieces[_Slot.front], _pieces[_Slot.back]]
        .whereType<File>()
        .toList();
    try {
      final raw = completing
          ? await api.addVerificationDocuments(
              identity: identity,
              selfie: _pieces[_Slot.selfie],
            )
          : await api.submitVerification(
              identity: identity,
              selfie: _pieces[_Slot.selfie]!,
            );
      if (mounted) _apply(raw);
    } catch (e) {
      if (mounted) afficherErreur(context, e, domaine: ErrorDomain.profil);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        content: Text(l10n.verificationCancelConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(l10n.notNow),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.verificationCancel,
                style: TextStyle(color: context.colors.error)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final raw = await context.read<TalkyApiClient>().cancelVerification();
      if (mounted) _apply(raw);
    } catch (e) {
      if (mounted) afficherErreur(context, e, domaine: ErrorDomain.profil);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Écran ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = _state;
    final request = state?.request;
    final depositing = state != null &&
        (state.canSubmit ||
            request?.status == VerificationRequestStatus.documentRequested);

    return Scaffold(
      backgroundColor: context.semantic.surfaceMuted,
      appBar: AppBar(
        title: Text(request == null || depositing && state.canSubmit
            ? l10n.verificationTitle
            : l10n.verificationStatusTitle),
      ),
      body: state == null
          ? (_error == null
              ? const Center(child: CircularProgressIndicator())
              : _LoadError(error: _error, onRetry: _load))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.xxl,
                ),
                children: [
                  ..._statusBlock(context, state),
                  if (depositing) ..._depositBlock(context, state),
                ],
              ),
            ),
      bottomNavigationBar: state == null ? null : _bottomBar(context, state),
    );
  }

  /// Ce qui précède le formulaire, selon l'état du dossier et de la coche.
  List<Widget> _statusBlock(BuildContext context, VerificationState state) {
    final l10n = context.l10n;
    final request = state.request;
    final widgets = <Widget>[];

    if (!state.available && state.canSubmit) {
      widgets.add(_Notice(
        icon: Icons.schedule_rounded,
        text: l10n.verificationUnavailableBody,
      ));
      widgets.add(AppSpacing.vGapLg);
    }

    if (state.isVerified || state.isPaused) {
      final until = state.until;
      widgets.add(_StatusCard(
        leading: const VerifiedSeal(size: 40),
        title: state.isPaused
            ? l10n.verificationPausedTitle
            : l10n.verificationApprovedTitle,
        body: state.isPaused
            ? l10n.verificationPausedBody
            : until != null
                ? l10n.verificationApprovedUntil(formatPlusDate(context, until))
                : l10n.verificationApprovedFree,
      ));
      widgets.add(AppSpacing.vGapMd);
      widgets.add(_Notice(
        icon: Icons.info_outline_rounded,
        text: l10n.verificationNameWarning,
        warn: true,
      ));
      return widgets;
    }

    switch (request?.status) {
      case VerificationRequestStatus.pending:
        final created = request!.createdAt ?? DateTime.now();
        widgets.addAll([
          _StatusCard(
            leading: _Disc(icon: Icons.hourglass_top_rounded),
            title: l10n.verificationPendingTitle,
            body: l10n.verificationPendingBody(formatPlusDate(context, created)),
          ),
          AppSpacing.vGapLg,
          Material(
            color: context.colors.surface,
            borderRadius: AppRadius.brMd,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                children: [
                  PlusTimelineStep(
                    state: PlusStepState.done,
                    title: l10n.verificationStepSent,
                    subtitle: formatPlusShortDate(context, created),
                  ),
                  PlusTimelineStep(
                    state: PlusStepState.done,
                    title: l10n.verificationStepPieces,
                    subtitle: '${state.documents.length}',
                  ),
                  PlusTimelineStep(
                    state: PlusStepState.current,
                    title: l10n.verificationStepReview,
                    subtitle: l10n.verificationStepInProgress,
                  ),
                  PlusTimelineStep(
                    state: PlusStepState.todo,
                    title: l10n.verificationStepDecision,
                    subtitle: l10n.verificationStepDecisionHint,
                    last: true,
                  ),
                ],
              ),
            ),
          ),
          if (context.watch<EntitlementService>().current.isSubscribed) ...[
            AppSpacing.vGapMd,
            _Notice(
              icon: Icons.check_circle_outline_rounded,
              text: l10n.verificationPlusNotWaiting,
            ),
          ],
        ]);
      case VerificationRequestStatus.documentRequested:
        widgets.addAll([
          _StatusCard(
            leading: _Disc(icon: Icons.upload_file_rounded, warn: true),
            title: l10n.verificationDocRequestedTitle,
            body: request!.reason ?? '',
          ),
          AppSpacing.vGapLg,
        ]);
      case VerificationRequestStatus.refused:
      case VerificationRequestStatus.revoked:
        final revoked = request!.status == VerificationRequestStatus.revoked;
        widgets.addAll([
          _StatusCard(
            leading: _Disc(icon: Icons.block_rounded, error: true),
            title: revoked
                ? l10n.verificationRevokedTitle
                : l10n.verificationRefusedTitle,
            body: [
              if ((request.reason ?? '').isNotEmpty)
                l10n.verificationReason(request.reason!),
              l10n.verificationResubmitHint,
            ].join('\n'),
          ),
          AppSpacing.vGapLg,
        ]);
      case VerificationRequestStatus.approved:
        if (request!.nameChanged) {
          widgets.addAll([
            _StatusCard(
              leading: _Disc(icon: Icons.drive_file_rename_outline, warn: true),
              title: l10n.verificationRenamedTitle,
              body: l10n.verificationRenamedBody,
            ),
            AppSpacing.vGapLg,
          ]);
        }
      case VerificationRequestStatus.cancelled:
      case null:
        break;
    }
    return widgets;
  }

  /// Le formulaire : nom à vérifier, pièces, confidentialité.
  List<Widget> _depositBlock(BuildContext context, VerificationState state) {
    final l10n = context.l10n;
    final completing =
        state.request?.status == VerificationRequestStatus.documentRequested;
    return [
      if (!completing) ...[
        Text(
          l10n.verificationIntro,
          style: context.text.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        AppSpacing.vGapLg,
        Material(
          color: context.colors.surface,
          borderRadius: AppRadius.brMd,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.verificationNameLabel,
                  style: context.text.labelMedium
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
                const SizedBox(height: 2),
                Text(
                  state.currentName,
                  style: context.text.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.verificationNameHint,
                  style: context.text.bodySmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        AppSpacing.vGapXl,
      ],
      PlusSectionLabel(l10n.verificationToProvide),
      _PieceTile(
        icon: Icons.badge_outlined,
        title: l10n.verificationIdFront,
        subtitle: l10n.verificationIdFrontHint,
        file: _pieces[_Slot.front],
        onTap: () => _pick(_Slot.front),
      ),
      AppSpacing.vGapSm,
      _PieceTile(
        icon: Icons.flip_outlined,
        title: l10n.verificationIdBack,
        subtitle: l10n.verificationIdBackHint,
        file: _pieces[_Slot.back],
        onTap: () => _pick(_Slot.back),
      ),
      AppSpacing.vGapSm,
      _PieceTile(
        icon: Icons.face_retouching_natural_outlined,
        title: l10n.verificationSelfie,
        subtitle: l10n.verificationSelfieHint,
        file: _pieces[_Slot.selfie],
        onTap: () => _pick(_Slot.selfie),
      ),
      AppSpacing.vGapLg,
      _Notice(icon: Icons.lock_outline_rounded, text: l10n.verificationPrivacy),
    ];
  }

  Widget? _bottomBar(BuildContext context, VerificationState state) {
    final l10n = context.l10n;
    final status = state.request?.status;
    final completing = status == VerificationRequestStatus.documentRequested;

    if (status == VerificationRequestStatus.pending) {
      return SafeArea(
        minimum: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(AppSizes.buttonHeight),
            shape: const RoundedRectangleBorder(borderRadius: AppRadius.brSm),
          ),
          onPressed: _busy ? null : _cancel,
          child: Text(l10n.verificationCancel),
        ),
      );
    }
    if (!state.canSubmit && !completing) return null;

    final ready = completing
        ? _pieces.isNotEmpty
        : _pieces[_Slot.front] != null && _pieces[_Slot.selfie] != null;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
      child: FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(AppSizes.buttonHeight),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.brSm),
        ),
        onPressed: ready && !_busy && state.available ? _send : null,
        child: _busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(
                completing ? l10n.verificationSendPieces : l10n.verificationSubmit,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
      ),
    );
  }
}

// ── Morceaux ────────────────────────────────────────────────────────────

class _PieceTile extends StatelessWidget {
  const _PieceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.file,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final File? file;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final picked = file != null;
    return Material(
      color: context.colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.brSm,
        side: BorderSide(
          color: picked
              ? context.semantic.success.withValues(alpha: 0.6)
              : context.colors.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox.square(
                  dimension: 40,
                  child: picked
                      ? Image.file(file!, fit: BoxFit.cover)
                      : ColoredBox(
                          color: context.semantic.surfaceMuted,
                          child: Icon(icon,
                              size: 20, color: context.colors.onSurfaceVariant),
                        ),
                ),
              ),
              AppSpacing.hGapMd,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: context.text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 1),
                    Text(subtitle,
                        style: context.text.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(
                picked ? Icons.check_circle_rounded : Icons.add_circle_outline,
                color: picked ? context.semantic.success : context.colors.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.leading,
    required this.title,
    required this.body,
  });

  final Widget leading;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.brMd,
        side: BorderSide(color: context.colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            leading,
            AppSpacing.vGapMd,
            Text(
              title,
              textAlign: TextAlign.center,
              style:
                  context.text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (body.isNotEmpty) ...[
              AppSpacing.vGapXs,
              Text(
                body,
                textAlign: TextAlign.center,
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Disc extends StatelessWidget {
  const _Disc({required this.icon, this.warn = false, this.error = false});

  final IconData icon;
  final bool warn;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = error
        ? (context.colors.errorContainer, context.colors.error)
        : warn
            ? (context.semantic.warningContainer, context.semantic.warning)
            : (context.semantic.brandContainer, context.colors.primary);
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
      child: Icon(icon, size: 28, color: fg),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.warn = false});

  final IconData icon;
  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: warn
            ? context.semantic.warningContainer
            : context.semantic.brandContainer,
        borderRadius: AppRadius.brSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon,
              size: 20,
              color: warn ? context.semantic.warning : context.colors.primary),
          AppSpacing.hGapMd,
          Expanded(
            child: Text(
              text,
              style: context.text.bodySmall?.copyWith(
                color: warn
                    ? context.colors.onSurface
                    : context.semantic.onBrandContainer,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error, required this.onRetry});

  final Object? error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 40, color: context.colors.onSurfaceVariant),
            AppSpacing.vGapMd,
            Text(
              presenterErreur(context.l10n, error, domaine: ErrorDomain.profil),
              textAlign: TextAlign.center,
              style: context.text.bodyMedium
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            AppSpacing.vGapLg,
            OutlinedButton(
              onPressed: onRetry,
              child: Text(context.l10n.retry),
            ),
          ],
        ),
      ),
    );
  }
}
