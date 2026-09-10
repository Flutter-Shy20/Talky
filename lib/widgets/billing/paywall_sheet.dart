import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services/billing/billing_models.dart';
import '../../core/services/billing/entitlement_service.dart';
import '../../core/services/billing/entitlements.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../l10n/app_localizations.dart';
import '../../screens/billing/plus_offer_screen.dart';
import '../common/app_bottom_sheet.dart';
import 'plus_visuals.dart';

/// Ouvre le panneau d'une fonctionnalité Alanya Plus verrouillée.
///
/// Un refus `SUBSCRIPTION_REQUIRED` n'est pas une panne : c'est une
/// proposition, faite sur la fonctionnalité demandée. `afficherErreur` ouvre
/// ce panneau pour toute route verrouillée côté serveur ; les écrans qui
/// savent déjà, par les droits en cache, que la fonctionnalité est fermée
/// l'ouvrent eux-mêmes par [guardPlus] — sans aller-retour pour rien.
Future<void> showPaywall(BuildContext context, PlusFeature? feature) async {
  if (!context.mounted) return;
  await showAppBottomSheet<void>(
    context: context,
    builder: (_) => PaywallSheet(feature: feature),
  );
}

/// Vrai si [feature] est ouverte. Sinon ouvre le panneau et rend faux :
///
/// ```dart
/// if (!guardPlus(context, PlusFeature.backup)) return;
/// ```
bool guardPlus(BuildContext context, PlusFeature feature) {
  if (EntitlementService.allows(feature)) return true;
  unawaited(showPaywall(context, feature));
  return false;
}

class PaywallSheet extends StatefulWidget {
  const PaywallSheet({super.key, this.feature});

  /// Nulle quand le serveur n'a pas dit laquelle : texte générique.
  final PlusFeature? feature;

  @override
  State<PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<PaywallSheet> {
  @override
  void initState() {
    super.initState();
    // Le prix vient de l'offre : chargée une fois, gardée en cache ensuite.
    final service = EntitlementService.maybeInstance;
    if (service != null) unawaited(service.ensureOffer());
  }

  void _openOffer() {
    final navigator = Navigator.of(context);
    navigator.pop();
    unawaited(navigator.push(
      MaterialPageRoute(builder: (_) => const PlusOfferScreen()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final service = EntitlementService.maybeInstance;
    if (service == null) return _content(context, null);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => _content(context, service.offer),
    );
  }

  Widget _content(BuildContext context, PlusOffer? offer) {
    final l10n = context.l10n;
    final feature = widget.feature;
    final (title, body) = paywallCopy(l10n, feature);
    final lowest = offer?.lowestMonthly;

    return AppBottomSheet(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xs,
        AppSpacing.xl,
        AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              feature == null
                  ? Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: context.semantic.brandContainer,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Icon(Icons.workspace_premium_outlined,
                          color: context.colors.primary),
                    )
                  : PlusFeatureGlyph(
                      feature: feature,
                      size: 44,
                      radius: AppRadius.sm,
                    ),
              AppSpacing.hGapMd,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: context.text.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    const PlusTag(),
                  ],
                ),
              ),
            ],
          ),
          AppSpacing.vGapMd,
          Text(
            body,
            style: context.text.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          if (lowest != null) ...[
            AppSpacing.vGapLg,
            const Divider(height: 1),
            AppSpacing.vGapMd,
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    l10n.paywallFromLabel,
                    style: context.text.bodySmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                ),
                Text(
                  '${formatPlusAmount(context, lowest)} ${l10n.plusPerMonth}',
                  style: context.text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ],
          AppSpacing.vGapLg,
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(AppSizes.buttonHeight),
            ),
            onPressed: _openOffer,
            child: Text(l10n.paywallSeeOffer),
          ),
          AppSpacing.vGapXs,
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.later),
          ),
        ],
      ),
    );
  }
}

/// Bandeau posé en tête d'un écran dont la fonctionnalité est verrouillée :
/// dit ce qui est fermé, ce qui reste, et mène au panneau.
class PlusLockedBanner extends StatelessWidget {
  const PlusLockedBanner({
    super.key,
    required this.feature,
    required this.text,
  });

  final PlusFeature feature;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.semantic.brandContainer,
      borderRadius: AppRadius.brMd,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showPaywall(context, feature),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
          ),
          child: Row(
            children: [
              Icon(Icons.lock_outline_rounded,
                  size: 20, color: context.colors.primary),
              AppSpacing.hGapMd,
              Expanded(
                child: Text(
                  text,
                  style: context.text.bodySmall?.copyWith(
                    color: context.semantic.onBrandContainer,
                    height: 1.4,
                  ),
                ),
              ),
              AppSpacing.hGapSm,
              Text(
                context.l10n.paywallSeeOffer,
                style: context.text.labelLarge?.copyWith(
                  color: context.colors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: context.colors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Titre et texte du panneau, par fonctionnalité.
(String, String) paywallCopy(AppLocalizations l10n, PlusFeature? feature) =>
    switch (feature) {
      PlusFeature.translation => (
          l10n.paywallTranslationTitle,
          l10n.paywallTranslationBody,
        ),
      PlusFeature.backup => (l10n.paywallBackupTitle, l10n.paywallBackupBody),
      PlusFeature.trustedTrips => (
          l10n.paywallTripsTitle,
          l10n.paywallTripsBody,
        ),
      PlusFeature.listRingtones => (
          l10n.paywallRingtonesTitle,
          l10n.paywallRingtonesBody,
        ),
      _ => (l10n.paywallGenericTitle, l10n.paywallGenericBody),
    };
