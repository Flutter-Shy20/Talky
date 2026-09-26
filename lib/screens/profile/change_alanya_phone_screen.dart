import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/afficher_erreur.dart';
import '../../core/errors/app_error.dart';
import '../../core/services/billing/billing_models.dart';
import '../../core/services/billing/phone_models.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/alanya_phone_formatter.dart';
import '../../providers/auth_provider.dart';
import '../../talky_api_client.dart';
import '../../widgets/alanya_phone_field.dart';
import '../../widgets/billing/mobile_money_checkout.dart';
import '../../widgets/billing/plus_visuals.dart';

/// Choisir un numéro Alanya plus facile à retenir : vérifier, réserver, payer.
///
/// Le serveur tranche tout — ce qui est à vendre, le prix, la durée de la
/// réservation. L'écran suit la commande qu'il lui rend : rien, un numéro
/// réservé, un paiement en cours, ou un changement payé qui attend son numéro
/// (crédit). Rouvert au milieu d'un achat, il reprend là où il en était.
class ChangeAlanyaPhoneScreen extends StatefulWidget {
  const ChangeAlanyaPhoneScreen({super.key, this.initialOffer});

  /// L'offre déjà lue par l'écran d'entrée : l'écran s'ouvre sans attente,
  /// puis la relit.
  final PhoneOffer? initialOffer;

  @override
  State<ChangeAlanyaPhoneScreen> createState() =>
      _ChangeAlanyaPhoneScreenState();
}

class _ChangeAlanyaPhoneScreenState extends State<ChangeAlanyaPhoneScreen> {
  final _number = TextEditingController();

  PhoneOffer? _offer;
  bool _loadFailed = false;
  bool _busy = false;
  String? _fieldError;
  PhoneAvailability? _availability;

  /// Numéro posé tout de suite grâce à un crédit : l'écran devient le succès.
  String? _appliedPhone;

  TalkyApiClient get _api => context.read<TalkyApiClient>();

  @override
  void initState() {
    super.initState();
    _offer = widget.initialOffer;
    unawaited(_loadOffer());
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _loadOffer() async {
    try {
      final offer = PhoneOffer.fromJson(await _api.getPhoneOffer());
      if (!mounted) return;
      setState(() {
        _offer = offer;
        _loadFailed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = _offer == null);
    }
  }

  String get _canonical => AlanyaPhoneFormatter.normalize(_number.text);

  void _onChanged(String _) {
    if (_availability != null || _fieldError != null) {
      setState(() {
        _availability = null;
        _fieldError = null;
      });
    }
  }

  // ── Vérifier ────────────────────────────────────────────────────────

  Future<void> _check() async {
    final phone = _canonical;
    if (phone.length != 8) {
      setState(() => _fieldError = context.l10n.phoneChangeMustBe8);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _fieldError = null;
      _availability = null;
    });
    try {
      final a = PhoneAvailability.fromJson(await _api.checkAlanyaPhone(phone));
      if (mounted) setState(() => _availability = a);
    } catch (e) {
      if (mounted) afficherErreur(context, e, domaine: ErrorDomain.profil);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Réserver ────────────────────────────────────────────────────────

  Future<void> _hold() async {
    final phone = _availability?.phone;
    if (phone == null) return;
    setState(() => _busy = true);
    try {
      final r = PhoneHoldResult.fromJson(await _api.holdAlanyaPhone(phone));
      if (!mounted) return;
      if (r.applied) {
        // Le numéro est posé côté serveur : une relecture ratée du profil ne
        // doit pas le faire passer pour un échec.
        final auth = context.read<AuthProvider>();
        unawaited(auth.refreshProfile().catchError((Object _) {}));
        setState(() => _appliedPhone = r.phone);
        return;
      }
      final order = r.order;
      if (r.credit || order == null) {
        // Pris dans l'instant : le crédit reste, on choisit un autre numéro.
        setState(() => _availability = PhoneAvailability(
            phone: phone, available: false, reason: PhoneRefusal.taken));
        await _loadOffer();
        return;
      }
      await _pay(order);
    } on TalkyException catch (e) {
      if (!mounted) return;
      final reason = PhoneRefusal.fromWire(e.details?['reason']);
      if (e.code == 'PHONE_UNAVAILABLE' && reason != null) {
        setState(() => _availability =
            PhoneAvailability(phone: phone, available: false, reason: reason));
      } else if (e.code == 'PHONE_ORDER_PENDING') {
        // Un autre appareil a lancé un paiement : l'offre relue le montre.
        await _loadOffer();
      } else {
        afficherErreur(context, e, domaine: ErrorDomain.profil);
      }
    } catch (e) {
      if (mounted) afficherErreur(context, e, domaine: ErrorDomain.profil);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _release() async {
    setState(() => _busy = true);
    try {
      await _api.releaseAlanyaPhoneHold();
    } catch (e) {
      if (mounted) afficherErreur(context, e, domaine: ErrorDomain.profil);
    }
    await _loadOffer();
    if (mounted) setState(() => _busy = false);
  }

  // ── Payer ───────────────────────────────────────────────────────────

  /// Paie une commande réservée, ou reprend l'attente d'un paiement en cours.
  Future<void> _pay(PhoneOrder order) async {
    final offer = _offer ?? PhoneOffer.unavailable;
    final l10n = context.l10n;
    final api = _api;
    final auth = context.read<AuthProvider>();
    final amount = formatPlusAmount(context, offer.price);
    // Numéro posé ou crédit : c'est le serveur qui le dit, relu après la
    // confirmation — pas le profil local, qui a pu ne pas se rafraîchir.
    var credit = false;

    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => MobileMoneyCheckout(
          title: l10n.checkoutTitle,
          doneTitle: l10n.phoneChangeProduct,
          channels: offer.provider?.channels ?? const [],
          simulated: offer.provider?.simulated ?? false,
          amount: amount,
          summary: _PhoneSummary(order: order, amount: amount),
          submit: (channel, msisdn) async {
            final r = CheckoutResult.fromJson(await api.checkoutAlanyaPhone(
              orderId: order.id,
              channel: channel.wire,
              msisdn: msisdn,
            ));
            return r.paymentId;
          },
          resumePaymentId:
              order.status == PhoneOrderStatus.paying ? order.paymentId : null,
          activatedStep: l10n.phoneChangeStepApplied,
          leaveHint: l10n.phoneChangeLeaveHint,
          // Le serveur a changé le numéro dans la transaction du paiement :
          // le profil relu le porte déjà — sauf crédit, que l'offre signale.
          onSucceeded: (_) async {
            try {
              credit = PhoneOffer.fromJson(await api.getPhoneOffer()).credit;
            } catch (_) {}
            await auth.refreshProfile();
          },
          succeeded: (context, _) => credit
              ? const _PhoneCreditOutcome()
              : _PhoneAppliedOutcome(phone: order.phone),
          // Après un échec la commande est abandonnée : on revient choisir,
          // le numéro toujours saisi.
          onRetry: () => Navigator.pop(context),
        ),
      ),
    );
    if (!mounted) return;
    // Revenu sans payer : le numéro redevient libre pour les autres. Sans
    // effet sur un paiement déjà demandé, qui attend sa réponse.
    if (done == null) unawaited(api.releaseAlanyaPhoneHold().catchError((_) {}));
    if (done == true) {
      Navigator.pop(context, true);
      return;
    }
    await _loadOffer();
  }

  // ── Écran ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final applied = _appliedPhone;

    return Scaffold(
      backgroundColor: context.semantic.surfaceMuted,
      appBar: AppBar(
        backgroundColor: context.semantic.surfaceMuted,
        title: Text(applied != null ? l10n.phoneChangeProduct : l10n.phoneChangeTitle),
      ),
      body: applied != null
          ? _PhoneAppliedOutcome(phone: applied)
          : _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final l10n = context.l10n;
    final offer = _offer;
    if (offer == null) {
      return Center(
        child: _loadFailed
            ? Padding(
                padding: AppSpacing.screenH,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.phoneChangeUnavailable, textAlign: TextAlign.center),
                    AppSpacing.vGapMd,
                    OutlinedButton(onPressed: _loadOffer, child: Text(l10n.retry)),
                  ],
                ),
              )
            : const CircularProgressIndicator(),
      );
    }
    if (!offer.purchasable) {
      return Center(
        child: Padding(
          padding: AppSpacing.screenH,
          child: Text(l10n.phoneChangeUnavailable, textAlign: TextAlign.center),
        ),
      );
    }

    final order = offer.order;
    final paying = order?.status == PhoneOrderStatus.paying;
    final held = order?.status == PhoneOrderStatus.held &&
        (order?.heldUntil?.isAfter(DateTime.now()) ?? false);
    final amount = formatPlusAmount(context, offer.price);
    final current = context.watch<AuthProvider>().currentUser?.alanyaPhone ??
        offer.currentPhone;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              _CurrentNumberCard(phone: current),
              AppSpacing.vGapXl,
              if (offer.credit) ...[
                _Notice(
                  icon: Icons.info_outline_rounded,
                  text: l10n.phoneChangeCreditBanner,
                ),
                AppSpacing.vGapLg,
              ],
              if (paying)
                _Notice(
                  icon: Icons.hourglass_top_rounded,
                  text: l10n.phoneChangePending(
                      AlanyaPhoneFormatter.formatDisplay(order!.phone)),
                )
              else if (held)
                _Notice(
                  icon: Icons.lock_clock_outlined,
                  text: l10n.phoneChangeHeldUntil(
                    AlanyaPhoneFormatter.formatDisplay(order!.phone),
                    _time(context, order.heldUntil!),
                  ),
                )
              else ...[
                Text(
                  offer.credit ? l10n.phoneChangeFieldLabel : l10n.phoneChangeIntro(amount),
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
                AppSpacing.vGapLg,
                AlanyaPhoneField(
                  controller: _number,
                  onChanged: _onChanged,
                  decoration: InputDecoration(
                    labelText: l10n.phoneChangeFieldLabel,
                    hintText: '12 34 56 78',
                    prefixIcon: const Icon(Icons.dialpad_rounded),
                    errorText: _fieldError,
                    filled: true,
                    fillColor: context.colors.surface,
                    border: const OutlineInputBorder(borderRadius: AppRadius.brSm),
                  ),
                ),
                if (_availability case final a?) ...[
                  AppSpacing.vGapMd,
                  _AvailabilityLine(availability: a, amount: amount),
                ],
              ],
              AppSpacing.vGapXl,
              Text(
                l10n.phoneChangeLoginNote,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (paying)
                _PrimaryButton(
                  label: l10n.phoneChangeSeeWaiting,
                  busy: _busy,
                  onPressed: () => _pay(order!),
                )
              else if (held) ...[
                _PrimaryButton(
                  label: l10n.checkoutPay(amount),
                  busy: _busy,
                  onPressed: () => _pay(order!),
                ),
                TextButton(
                  onPressed: _busy ? null : _release,
                  child: Text(l10n.phoneChangeReleaseHold),
                ),
              ] else if (_availability?.available ?? false)
                _PrimaryButton(
                  label: offer.credit
                      ? l10n.phoneChangeUseCredit
                      : l10n.phoneChangeReserveAndPay(amount),
                  busy: _busy,
                  onPressed: _hold,
                )
              else
                _PrimaryButton(
                  label: l10n.phoneChangeCheck,
                  busy: _busy,
                  onPressed: _check,
                ),
            ],
          ),
        ),
      ],
    );
  }

  static String _time(BuildContext context, DateTime at) =>
      MaterialLocalizations.of(context)
          .formatTimeOfDay(TimeOfDay.fromDateTime(at.toLocal()));
}

/// Le numéro, en grand : c'est ce qu'on achète, et ce qu'on retiendra.
class _BigNumber extends StatelessWidget {
  const _BigNumber(this.phone, {this.color});

  final String phone;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      AlanyaPhoneFormatter.formatDisplay(phone),
      style: context.text.headlineSmall?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: 1.5,
        fontFeatures: kTabularFigures,
        color: color,
      ),
    );
  }
}

class _CurrentNumberCard extends StatelessWidget {
  const _CurrentNumberCard({required this.phone});

  final String phone;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.brSm,
        side: BorderSide(color: context.colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.phoneChangeCurrent,
              style: context.text.labelMedium
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: 2),
            _BigNumber(phone),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.semantic.infoContainer,
        borderRadius: AppRadius.brSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: context.semantic.info),
          AppSpacing.hGapSm,
          Expanded(
            child: Text(
              text,
              style: context.text.bodyMedium?.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _AvailabilityLine extends StatelessWidget {
  const _AvailabilityLine({required this.availability, required this.amount});

  final PhoneAvailability availability;
  final String amount;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (availability.available) {
      return Row(
        children: [
          Icon(Icons.check_circle_rounded, size: 20, color: context.semantic.success),
          AppSpacing.hGapSm,
          Text(
            '${l10n.phoneChangeAvailable} · $amount',
            style: context.text.bodyMedium?.copyWith(
              color: context.semantic.success,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }
    final text = switch (availability.reason) {
      PhoneRefusal.same => l10n.phoneChangeReasonSame,
      PhoneRefusal.taken => l10n.phoneChangeReasonTaken,
      PhoneRefusal.setAside => l10n.phoneChangeReasonSetAside,
      PhoneRefusal.held => l10n.phoneChangeReasonHeld,
      PhoneRefusal.quarantine => l10n.phoneChangeReasonQuarantine,
      null => l10n.errCodePhoneUnavailable,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.block_rounded, size: 20, color: context.colors.error),
        AppSpacing.hGapSm,
        Expanded(
          child: Text(
            text,
            style: context.text.bodyMedium?.copyWith(color: context.colors.error),
          ),
        ),
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSizes.buttonHeight),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.brSm),
      ),
      onPressed: busy ? null : onPressed,
      child: busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}

/// Récapitulatif du paiement : le numéro acheté et la fin de sa réservation.
class _PhoneSummary extends StatelessWidget {
  const _PhoneSummary({required this.order, required this.amount});

  final PhoneOrder order;
  final String amount;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final until = order.heldUntil;
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
                    l10n.phoneChangeProduct,
                    style: context.text.labelMedium
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                  _BigNumber(order.phone),
                  if (until != null && order.status == PhoneOrderStatus.held)
                    Text(
                      l10n.phoneChangeSummaryHeld(
                          _ChangeAlanyaPhoneScreenState._time(context, until)),
                      style: context.text.bodySmall
                          ?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            Text(
              amount,
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
}

/// Paiement confirmé, mais le numéro a été pris dans l'intervalle (course
/// rarissime) : le paiement devient un crédit, on choisit un autre numéro.
class _PhoneCreditOutcome extends StatelessWidget {
  const _PhoneCreditOutcome();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return CheckoutOutcome(
      icon: Icons.info_outline_rounded,
      iconColor: context.semantic.info,
      disc: context.semantic.infoContainer,
      title: l10n.phoneChangeCreditTitle,
      body: l10n.phoneChangeCreditBody,
      primary: l10n.phoneChangeChooseAnother,
      onPrimary: () => Navigator.pop(context, false),
    );
  }
}

class _PhoneAppliedOutcome extends StatelessWidget {
  const _PhoneAppliedOutcome({required this.phone});

  final String phone;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return CheckoutOutcome(
      icon: Icons.check_rounded,
      iconColor: Colors.white,
      disc: context.semantic.success,
      title: l10n.phoneChangeSuccessTitle,
      body: l10n.phoneChangeSuccessBody,
      extra: Center(child: _BigNumber(phone, color: context.colors.primary)),
      primary: l10n.checkoutDone,
      onPrimary: () => Navigator.pop(context, true),
    );
  }
}
