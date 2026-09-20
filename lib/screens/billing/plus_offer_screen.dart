import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_error.dart';
import '../../core/errors/error_presenter.dart';
import '../../core/services/billing/billing_models.dart';
import '../../core/services/billing/entitlement_service.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/billing/plus_visuals.dart';
import 'checkout_screen.dart';

/// L'offre Alanya Plus : ce qu'elle débloque, les durées, la date de départ.
///
/// Tout vient du serveur (plans modifiables en administration). L'annuel est
/// présélectionné, et la première période est dite en toutes lettres : payer
/// pendant la grâce ne fait perdre aucun jour gratuit, renouveler en avance
/// n'en fait perdre aucun non plus.
class PlusOfferScreen extends StatefulWidget {
  const PlusOfferScreen({super.key, this.initialPlanCode});

  /// Plan à présélectionner (renouvellement depuis « Mon abonnement »).
  final String? initialPlanCode;

  @override
  State<PlusOfferScreen> createState() => _PlusOfferScreenState();
}

class _PlusOfferScreenState extends State<PlusOfferScreen> {
  PlusOffer? _offer;
  Object? _error;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _offer = context.read<EntitlementService>().offer;
    _selected = widget.initialPlanCode;
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final offer = await context.read<EntitlementService>().loadOffer();
      if (!mounted) return;
      setState(() {
        _offer = offer;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  PlusPlan? _plan(PlusOffer offer) =>
      offer.planByCode(_selected) ?? offer.defaultPlan;

  Future<void> _continue(PlusOffer offer, PlusPlan plan) async {
    final paid = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CheckoutScreen(offer: offer, plan: plan),
      ),
    );
    if (paid == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final offer = _offer;
    final plan = offer == null ? null : _plan(offer);
    final canBuy = offer != null && offer.purchasable && plan != null;

    return Scaffold(
      backgroundColor: context.semantic.surfaceMuted,
      appBar: AppBar(title: Text(l10n.plusBrand)),
      body: offer == null
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
                  PlusSectionLabel(l10n.plusOfferUnlocks),
                  _FeatureList(offer: offer),
                  AppSpacing.vGapXl,
                  if (!offer.purchasable || plan == null)
                    _Note(
                      icon: Icons.schedule_rounded,
                      text: l10n.plusOfferUnavailable,
                    )
                  else ...[
                    // Un seul plan actif (annuel) : le prix et le bouton
                    // suffisent, sans sélecteur de durée.
                    if (offer.plans.length > 1) ...[
                      PlusSectionLabel(l10n.plusOfferDuration),
                      for (final p in offer.plans) ...[
                        _PlanOption(
                          plan: p,
                          reference: offer.reference,
                          selected: p.code == plan.code,
                          onTap: () => setState(() => _selected = p.code),
                        ),
                        AppSpacing.vGapSm,
                      ],
                      AppSpacing.vGapSm,
                    ],
                    _FinePrint(offer: offer, plan: plan),
                  ],
                ],
              ),
            ),
      bottomNavigationBar: canBuy
          ? SafeArea(
              minimum: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(AppSizes.buttonHeight),
                  shape: const RoundedRectangleBorder(
                      borderRadius: AppRadius.brSm),
                ),
                onPressed: () => _continue(offer, plan),
                child: Text(
                  l10n.plusOfferContinue(formatPlusAmount(context, plan.price)),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            )
          : null,
    );
  }
}

class _FeatureList extends StatelessWidget {
  const _FeatureList({required this.offer});

  final PlusOffer offer;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final lang = Localizations.localeOf(context).languageCode;
    // Le catalogue serveur fait foi ; sans lui (réponse ancienne), la liste
    // locale évite un écran vide.
    final rows = offer.features.isNotEmpty
        ? [
            for (final f in offer.features)
              (f.feature, f.nameFor(lang), f.descriptionFor(lang)),
          ]
        : [
            for (final f in kPlusShowcase)
              (f, plusFeatureName(l10n, f), ''),
          ];

    return Material(
      color: context.colors.surface,
      borderRadius: AppRadius.brMd,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                indent: AppSpacing.lg + 36 + AppSpacing.md,
                color: context.colors.outlineVariant,
              ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md,
              ),
              child: Row(
                children: [
                  rows[i].$1 == null
                      ? Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: context.semantic.brandContainer,
                          ),
                          child: Icon(Icons.star_outline_rounded,
                              size: 18, color: context.colors.primary),
                        )
                      : PlusFeatureGlyph(feature: rows[i].$1!, size: 36),
                  AppSpacing.hGapMd,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          rows[i].$2,
                          style: context.text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        if (rows[i].$3.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            rows[i].$3,
                            style: context.text.bodySmall?.copyWith(
                              color: context.colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlanOption extends StatelessWidget {
  const _PlanOption({
    required this.plan,
    required this.reference,
    required this.selected,
    required this.onTap,
  });

  final PlusPlan plan;
  final PlusPlan? reference;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final lang = Localizations.localeOf(context).languageCode;
    final offered = plan.monthsOffered(reference);
    final name = plan.nameFor(lang);
    final primary = context.colors.primary;

    return AnimatedContainer(
      duration: AppDurations.fast,
      decoration: BoxDecoration(
        borderRadius: AppRadius.brSm,
        boxShadow: selected
            ? [
                BoxShadow(
                  color: primary.withValues(alpha: 0.16),
                  spreadRadius: 3,
                ),
              ]
            : null,
      ),
      child: Material(
        color: context.colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.brSm,
          side: BorderSide(
            color: selected ? primary : context.colors.outlineVariant,
            width: 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                PlusChoiceDot(selected: selected),
                AppSpacing.hGapMd,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? plusPlanName(context, plan.code) : name,
                        style: context.text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        plan.durationMonths == 1
                            ? l10n.plusOfferNoCommitment
                            : l10n.plusOfferEquivalent(formatPlusAmount(
                                context, plan.monthlyEquivalent)),
                        style: context.text.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                          fontFeatures: kTabularFigures,
                        ),
                      ),
                      if (offered > 0) ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: context.semantic.successContainer,
                            borderRadius: AppRadius.brPill,
                          ),
                          child: Text(
                            l10n.plusOfferMonthsFree(offered).toUpperCase(),
                            style: context.text.labelSmall?.copyWith(
                              color: context.semantic.success,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                AppSpacing.hGapSm,
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: formatPlusAmount(context, plan.price),
                        style: context.text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          fontFeatures: kTabularFigures,
                        ),
                      ),
                      TextSpan(
                        text: ' ${plusPeriodSuffix(l10n, plan.durationMonths)}',
                        style: context.text.labelSmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// La date de départ et de fin, dites avant de payer.
class _FinePrint extends StatelessWidget {
  const _FinePrint({required this.offer, required this.plan});

  final PlusOffer offer;
  final PlusPlan plan;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final e = offer.entitlements;
    final start = plusNextPeriodStart(e, DateTime.now());
    final end = plusAddMonths(start, plan.durationMonths);
    final status = plusStatusOf(e);
    final renewing =
        status == PlusStatus.active || status == PlusStatus.scheduled;
    final period = renewing
        ? l10n.plusOfferNextPeriod(
            formatPlusDate(context, start), formatPlusDate(context, end))
        : l10n.plusOfferFirstPeriod(
            formatPlusDate(context, start), formatPlusDate(context, end));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Text(
        '$period ${l10n.plusOfferNoRefund}',
        style: context.text.bodySmall?.copyWith(
          color: context.colors.onSurfaceVariant,
          height: 1.45,
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.semantic.brandContainer,
        borderRadius: AppRadius.brSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: context.colors.primary),
          AppSpacing.hGapMd,
          Expanded(
            child: Text(
              text,
              style: context.text.bodyMedium?.copyWith(
                color: context.semantic.onBrandContainer,
                height: 1.4,
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
              presenterErreur(context.l10n, error,
                  domaine: ErrorDomain.abonnement),
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
