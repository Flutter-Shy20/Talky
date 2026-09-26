import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/billing/billing_models.dart';
import '../../core/services/billing/entitlement_service.dart';
import '../../core/services/billing/plus_status.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../talky_api_client.dart';
import '../../widgets/billing/mobile_money_checkout.dart';
import '../../widgets/billing/plus_visuals.dart';

/// Paiement mobile money d'un plan Alanya Plus.
///
/// Le formulaire, l'attente et l'échec sont ceux de [MobileMoneyCheckout] ;
/// restent ici ce qui tient à l'abonnement : les dates de la période achetée,
/// le renouvellement automatique, et ce que l'abonnement ouvre une fois payé.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({
    super.key,
    required this.offer,
    required this.plan,
  });

  final PlusOffer offer;
  final PlusPlan plan;

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  bool _autoRenew = false;

  @override
  void initState() {
    super.initState();
    _autoRenew =
        context.read<EntitlementService>().current.period?.autoRenew ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return MobileMoneyCheckout(
      title: l10n.checkoutTitle,
      doneTitle: l10n.plusBrand,
      channels: widget.offer.provider?.channels ?? const [],
      simulated: widget.offer.provider?.simulated ?? false,
      amount: formatPlusAmount(context, widget.plan.price),
      summary: _summary(context),
      options: _autoRenewSwitch,
      submit: (channel, msisdn) async {
        final api = context.read<TalkyApiClient>();
        final result = CheckoutResult.fromJson(await api.checkoutPlus(
          planCode: widget.plan.code,
          channel: channel.wire,
          msisdn: msisdn,
          autoRenew: _autoRenew,
        ));
        return result.paymentId;
      },
      activatedStep: l10n.checkoutStepActivated,
      leaveHint: l10n.checkoutLeaveHint,
      onSucceeded: (_) => context.read<EntitlementService>().refresh(),
      succeeded: (context, _) => _succeeded(context),
    );
  }

  /// Récapitulatif : ce qu'on achète, pour quelles dates.
  Widget _summary(BuildContext context) {
    final l10n = context.l10n;
    final lang = Localizations.localeOf(context).languageCode;
    final e = widget.offer.entitlements;
    final start = plusNextPeriodStart(e, DateTime.now());
    final end = plusAddMonths(start, widget.plan.durationMonths);
    final name = widget.plan.nameFor(lang);

    return Material(
      color: context.colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.brSm,
        side: BorderSide(color: context.colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${l10n.plusBrand} · '
                    '${name.isEmpty ? plusPlanName(context, widget.plan.code) : name}',
                    style: context.text.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${formatPlusShortDate(context, start)} → '
                    '${formatPlusShortDate(context, end)}',
                    style: context.text.bodySmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                      fontFeatures: kTabularFigures,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              formatPlusAmount(context, widget.plan.price),
              style: context.text.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                fontFeatures: kTabularFigures,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _autoRenewSwitch(BuildContext context, PaymentChannel channel) {
    final l10n = context.l10n;
    return Material(
      color: context.colors.surface,
      borderRadius: AppRadius.brSm,
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        value: _autoRenew,
        onChanged: (v) => setState(() => _autoRenew = v),
        title: Text(l10n.checkoutAutoRenew,
            style:
                context.text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text(l10n.checkoutAutoRenewHint(channel.brand)),
      ),
    );
  }

  Widget _succeeded(BuildContext context) {
    final l10n = context.l10n;
    final e = context.watch<EntitlementService>().current;
    final period = e.period ?? e.upcoming;
    final start = period?.startsAt;
    final end = period?.endsAt;
    final scheduled = start != null && start.isAfter(DateTime.now());

    return CheckoutOutcome(
      icon: Icons.check_rounded,
      iconColor: Colors.white,
      disc: context.semantic.success,
      title: l10n.checkoutSuccessTitle,
      body: [
        if (start != null && end != null)
          l10n.checkoutSuccessBody(
            plusPlanName(context, period!.plan, offer: widget.offer),
            formatPlusDate(context, start),
            formatPlusDate(context, end),
          ),
        if (scheduled) l10n.checkoutSuccessScheduled,
      ].join(' '),
      extra: Material(
        color: context.colors.surface,
        borderRadius: AppRadius.brMd,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Icon(Icons.check_circle_rounded,
                  size: 20, color: context.semantic.success),
              AppSpacing.hGapMd,
              Expanded(
                child: Text(
                  scheduled
                      ? l10n.checkoutSuccessFeaturesScheduled
                      : l10n.checkoutSuccessFeatures,
                  style: context.text.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
      primary: l10n.checkoutDone,
      onPrimary: () => Navigator.pop(context, true),
    );
  }
}
