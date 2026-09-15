import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/locale_controller.dart';

/// Accusé de réception unifié (liste + bulles).
/// 0=horloge, 1=✓, 2=✓✓, 3=✓✓ lu, 4=échec.
class MessageStatusIcon extends StatefulWidget {
  const MessageStatusIcon({
    super.key,
    required this.status,
    this.deliveredAt,
    this.readAt,
    this.size = 12,
    this.onBubble = false,
    this.timeFormatter,
    this.onRetry,
    this.pendingSince,
    this.grace = pendingGrace,
  });

  final int? status;
  final DateTime? deliveredAt;
  final DateTime? readAt;
  final double size;
  /// Sur bulle sortante : teinte onPrimary pour 0/1/2.
  final bool onBubble;
  final String Function(DateTime dt)? timeFormatter;
  /// Tap sur l’icône d’échec → réessayer l’envoi (menu long-press conservé ailleurs).
  final VoidCallback? onRetry;

  /// Instant du clic sur « envoyer ». Renseigné, l’horloge n’apparaît qu’après
  /// [grace] : voir la note sur ce délai.
  final DateTime? pendingSince;

  /// Délai effectif, [pendingGrace] par défaut. Paramétrable pour que les tests
  /// n’aient pas à courir après l’horloge murale.
  final Duration grace;

  /// Délai avant d’afficher l’horloge, façon WhatsApp.
  ///
  /// Un accusé qui revient en moins de 300 ms ne mérite pas d’être signalé :
  /// l’horloge n’aurait le temps que de clignoter, ce qui donne l’impression
  /// d’un envoi laborieux là où il ne s’est rien passé d’anormal. Au-delà du
  /// délai elle s’affiche normalement — l’attente est alors réelle et la
  /// masquer mentirait à l’utilisateur.
  static const Duration pendingGrace = Duration(milliseconds: 300);

  @override
  State<MessageStatusIcon> createState() => _MessageStatusIconState();
}

class _MessageStatusIconState extends State<MessageStatusIcon> {
  Timer? _graceTimer;

  /// Seul le timer fait retomber ce drapeau, jamais un calcul dans `build` :
  /// l’horloge murale n’est lue qu’au montage, pour savoir combien de temps il
  /// reste à attendre. Un `build` qui la relirait rendrait l’affichage
  /// dépendant du moment où Flutter décide de repeindre.
  bool _graceOver = true;

  @override
  void initState() {
    super.initState();
    _restartGrace();
  }

  @override
  void didUpdateWidget(covariant MessageStatusIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status != oldWidget.status ||
        widget.pendingSince != oldWidget.pendingSince ||
        widget.grace != oldWidget.grace) {
      _restartGrace();
    }
  }

  @override
  void dispose() {
    _graceTimer?.cancel();
    super.dispose();
  }

  /// Temps restant avant d’afficher l’horloge, ou `null` s’il n’y a rien à
  /// attendre (autre statut, instant d’envoi inconnu, délai déjà écoulé).
  Duration? _remainingGrace() {
    if ((widget.status ?? 1) != 0) return null;
    final since = widget.pendingSince;
    if (since == null) return null;
    final age = DateTime.now().difference(since);
    // Horodatage dans le futur (horloge de l’appareil décalée) : on affiche
    // plutôt que de masquer pour une durée imprévisible.
    if (age.isNegative) return null;
    final left = widget.grace - age;
    return left > Duration.zero ? left : null;
  }

  void _restartGrace() {
    _graceTimer?.cancel();
    _graceTimer = null;
    final remaining = _remainingGrace();
    if (remaining == null) {
      _graceOver = true;
      return;
    }
    _graceOver = false;
    // Un seul timer, et seulement pour une bulle encore dans la fenêtre : en
    // pratique le message qu’on vient d’envoyer, pas toute la liste.
    _graceTimer = Timer(remaining, () {
      if (mounted) setState(() => _graceOver = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.status ?? 1;

    // Place réservée à la taille exacte de l’icône : sans elle, l’arrivée du
    // ✓ décalerait l’heure et ferait sauter la bulle.
    if (!_graceOver) {
      return SizedBox(width: widget.size, height: widget.size);
    }

    final size = widget.size;
    final muted = widget.onBubble
        ? context.colors.onPrimary.withAlpha(180)
        : context.colors.onSurfaceVariant;
    final readColor = context.semantic.info;
    final errorColor = context.colors.error;

    String? tip;
    Widget icon;
    switch (s) {
      case 0:
        tip = context.l10n.statusPending;
        icon = Icon(Icons.schedule, size: size, color: muted);
      case 1:
        tip = context.l10n.statusSent;
        icon = Icon(Icons.check, size: size, color: muted);
      case 2:
        tip = widget.deliveredAt != null && widget.timeFormatter != null
            ? LocaleController.instance.l10n
                .deliveredAtTime(widget.timeFormatter!(widget.deliveredAt!))
            : context.l10n.statusDelivered;
        icon = Icon(Icons.done_all,
            size: size + (widget.onBubble ? 0 : 2), color: muted);
      case 3:
        tip = widget.readAt != null && widget.timeFormatter != null
            ? LocaleController.instance.l10n
                .readAtTime(widget.timeFormatter!(widget.readAt!))
            : context.l10n.statusRead;
        icon = Icon(Icons.done_all,
            size: size + (widget.onBubble ? 0 : 2), color: readColor);
      case 4:
        tip = widget.onRetry != null
            ? context.l10n.statusFailedRetry
            : context.l10n.longPressFailedTryAgain;
        icon = Icon(Icons.error_outline,
            size: size + (widget.onBubble ? 0 : 2), color: errorColor);
      default:
        return const SizedBox.shrink();
    }

    final child = Tooltip(message: tip, child: icon);
    if (s == 4 && widget.onRetry != null) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onRetry,
        child: child,
      );
    }
    return child;
  }
}
