import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Badge dérivé de `account_type` + `verification_status` — jamais stocké côté client.
enum AccountBadge {
  none,
  cocheVerifiee,
  panierDeclare,
  panierVerifie,
  officiel,
}

const Color kOfficialSealGold = Color(0xFFC9A227);

/// Indigo de la coche : `brandPrimary` (app_colors.dart). Il ne suit pas le
/// thème : c'est un sceau, il doit se reconnaître à l'identique partout.
/// Miroir de `VERIFIED_INDIGO` (alanya-admin, lib/account-badge.ts).
const Color kVerifiedIndigo = Color(0xFF3F51B5);

AccountBadge resolveAccountBadge(int accountType, int verificationStatus) {
  if (accountType == 2) return AccountBadge.officiel;
  if (accountType == 1) {
    return verificationStatus == 2
        ? AccountBadge.panierVerifie
        : AccountBadge.panierDeclare;
  }
  // Compte personnel : la coche n'apparaît que vérifié. En attente, refusé,
  // révoqué ou expiré, rien ne s'affiche.
  return verificationStatus == 2
      ? AccountBadge.cocheVerifiee
      : AccountBadge.none;
}

/// Ce qu'un lecteur d'écran annonce pour le badge.
String? accountBadgeSemanticLabel(BuildContext context, AccountBadge badge) {
  final l10n = context.l10n;
  return switch (badge) {
    AccountBadge.none => null,
    AccountBadge.cocheVerifiee => l10n.accountBadgeVerified,
    AccountBadge.panierDeclare => l10n.accountBadgeBusinessDeclared,
    AccountBadge.panierVerifie => l10n.accountBadgeBusinessVerified,
    AccountBadge.officiel => l10n.accountBadgeOfficial,
  };
}

class AccountBadgeIcon extends StatelessWidget {
  const AccountBadgeIcon({
    super.key,
    required this.accountType,
    required this.verificationStatus,
    this.size = 14,
  });

  final int accountType;
  final int verificationStatus;
  final double size;

  @override
  Widget build(BuildContext context) {
    final badge = resolveAccountBadge(accountType, verificationStatus);
    if (badge == AccountBadge.none) return const SizedBox.shrink();
    final Widget glyph = switch (badge) {
      AccountBadge.cocheVerifiee => VerifiedSeal(size: size),
      AccountBadge.officiel =>
        Icon(Icons.verified, size: size, color: kOfficialSealGold),
      AccountBadge.panierVerifie =>
        Icon(Icons.shopping_bag, size: size, color: Colors.green.shade700),
      _ => Icon(Icons.shopping_bag_outlined,
          size: size, color: Colors.blueGrey),
    };
    return Semantics(
      label: accountBadgeSemanticLabel(context, badge),
      image: true,
      child: ExcludeSemantics(child: glyph),
    );
  }
}

/// Le sceau festonné des documents de conception, en indigo, avec sa coche.
///
/// Rosace à 12 lobes, r(t) = R + A·cos(12t), dans un repère de 24 : un disque
/// plein se confondrait avec un avatar ou une pastille de comptage, le feston
/// se reconnaît même à 12 px. Même tracé que la maquette et que le badge de
/// l'administration.
class VerifiedSeal extends StatelessWidget {
  const VerifiedSeal({super.key, this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: const _SealPainter(kVerifiedIndigo),
    );
  }
}

class _SealPainter extends CustomPainter {
  const _SealPainter(this.color);

  final Color color;

  /// Calculé une fois : 288 points (un tous les 1,25°) donnent une ligne
  /// visuellement continue sans lissage — un tracé lissé ferait des lobes
  /// des pointes d'étoile.
  static final Path _seal = _buildSeal();

  static Path _buildSeal() {
    const r0 = 10.6, amplitude = 1.25, lobes = 12, steps = 288;
    final path = Path();
    for (var i = 0; i < steps; i++) {
      final t = i / steps * 2 * math.pi;
      final r = r0 + amplitude * math.cos(lobes * t);
      final x = 12 + r * math.cos(t);
      final y = 12 + r * math.sin(t);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path..close();
  }

  static final Path _check = Path()
    ..moveTo(6.6, 12.4)
    ..lineTo(10.1, 15.9)
    ..lineTo(17.6, 8.2);

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width / 24);
    canvas.drawPath(_seal, Paint()..color = color);
    // La coche est réduite au creux du feston, pas à sa crête.
    canvas
      ..translate(12, 12)
      ..scale(0.86)
      ..translate(-12, -12);
    canvas.drawPath(
      _check,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SealPainter oldDelegate) => oldDelegate.color != color;
}

/// Nom de contact + icône de badge inline (liste conversations, détail contact…).
class AccountBadgeLabel extends StatelessWidget {
  const AccountBadgeLabel({
    super.key,
    required this.name,
    required this.accountType,
    required this.verificationStatus,
    this.style,
    this.maxLines = 1,
  });

  final String name;
  final int accountType;
  final int verificationStatus;
  final TextStyle? style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final badge = resolveAccountBadge(accountType, verificationStatus);
    return Row(
      children: [
        Flexible(
          child: Text(
            name,
            style: style,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (badge != AccountBadge.none) ...[
          const SizedBox(width: 4),
          AccountBadgeIcon(
            accountType: accountType,
            verificationStatus: verificationStatus,
            size: (style?.fontSize ?? 14) + 2,
          ),
        ],
      ],
    );
  }
}
