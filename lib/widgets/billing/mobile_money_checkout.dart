import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/errors/afficher_erreur.dart';
import '../../core/errors/app_error.dart';
import '../../core/services/billing/billing_models.dart';
import '../../core/services/billing/entitlement_service.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../talky_api_client.dart';
import 'plus_visuals.dart';

/// Paiement mobile money : moyen, numéro, attente, résultat — le même pour
/// tout achat (Alanya Plus, numéro choisi). L'achat fournit ce qui lui est
/// propre : le récapitulatif, la demande, l'écran de succès.
///
/// **L'attente est le vrai sujet.** Un paiement mobile money est confirmé
/// quand l'opérateur prévient Alanya, pas quand on le demande : l'écran ne
/// conclut qu'à l'arrivée de `payment:updated` (ou, à défaut de socket, en
/// relisant le statut toutes les quelques secondes). Le simulateur répond par
/// le même chemin que le futur agrégateur — cet écran servira tel quel.
class MobileMoneyCheckout extends StatefulWidget {
  const MobileMoneyCheckout({
    super.key,
    required this.title,
    required this.doneTitle,
    required this.channels,
    required this.simulated,
    required this.amount,
    required this.summary,
    required this.submit,
    required this.activatedStep,
    required this.leaveHint,
    required this.succeeded,
    this.options,
    this.onSucceeded,
    this.onRetry,
    this.resumePaymentId,
  });

  /// Titre de la barre, puis titre une fois payé.
  final String title;
  final String doneTitle;

  /// Moyens proposés par le fournisseur ; vide = tous.
  final List<PaymentChannel> channels;

  /// Fournisseur simulé : l'écran prévient qu'aucun argent n'est débité.
  final bool simulated;

  /// Montant, déjà formaté.
  final String amount;

  /// Ce qu'on achète, en tête du formulaire.
  final Widget summary;

  /// Réglages propres à l'achat, sous le numéro à débiter (le renouvellement
  /// automatique de Plus). Reçoit le moyen choisi, que le texte peut nommer.
  final Widget Function(BuildContext context, PaymentChannel channel)? options;

  /// Demande le paiement et rend son identifiant. Une [TalkyException]
  /// `PAYMENT_PENDING` portant `paymentId` reprend l'attente de la demande
  /// existante au lieu d'en refuser une seconde.
  final Future<int> Function(PaymentChannel channel, String msisdn) submit;

  /// Troisième étape de l'attente : ce qui arrive à la confirmation.
  final String activatedStep;

  /// Sous le bouton « Quitter » : ce qui se passera sans l'utilisateur.
  final String leaveHint;

  /// Appelé à la confirmation, avant l'écran de succès : relire ce que le
  /// paiement a changé (droits, profil).
  final Future<void> Function(PlusPayment payment)? onSucceeded;

  final Widget Function(BuildContext context, PlusPayment payment) succeeded;

  /// « Réessayer » après un échec. Par défaut, retour au formulaire ; un
  /// achat qui doit repasser par une étape antérieure le remplace.
  final VoidCallback? onRetry;

  /// Une demande déjà partie (écran rouvert) : l'écran s'ouvre sur l'attente.
  final int? resumePaymentId;

  @override
  State<MobileMoneyCheckout> createState() => _MobileMoneyCheckoutState();
}

enum _Step { form, waiting, succeeded, failed }

class _MobileMoneyCheckoutState extends State<MobileMoneyCheckout> {
  static const _lastMsisdnKey = 'plus_last_msisdn';

  /// Au-delà, le serveur passe la demande en « expirée »
  /// (paymentService.reconcilePending).
  static const _requestLifetime = Duration(minutes: 30);
  static const _pollEvery = Duration(seconds: 6);

  final _number = TextEditingController();
  late PaymentChannel _channel;
  String? _numberError;
  bool _submitting = false;

  _Step _step = _Step.form;
  int? _paymentId;
  String? _msisdn;
  DateTime? _startedAt;
  PlusPayment? _result;
  bool _checking = false;

  StreamSubscription<PaymentUpdate>? _updates;
  Timer? _poll;
  Timer? _tick;

  List<PaymentChannel> get _channels =>
      widget.channels.isEmpty ? PaymentChannel.values : widget.channels;

  @override
  void initState() {
    super.initState();
    _channel = _channels.first;
    unawaited(_restoreNumber());
    final resume = widget.resumePaymentId;
    if (resume != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _wait(resume, null);
      });
    }
  }

  @override
  void dispose() {
    _stopWaiting();
    _number.dispose();
    super.dispose();
  }

  Future<void> _restoreNumber() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getString(_lastMsisdnKey);
      if (last == null || !mounted || _number.text.isNotEmpty) return;
      // Stocké au format serveur (2376…) ; affiché sans l'indicatif, déjà
      // porté par le préfixe du champ.
      _number.text = last.startsWith('237') ? last.substring(3) : last;
    } catch (_) {}
  }

  // ── Demande ─────────────────────────────────────────────────────────

  Future<void> _submit() async {
    final l10n = context.l10n;
    final msisdn = normalizeMsisdn(_number.text);
    if (msisdn == null) {
      setState(() => _numberError = l10n.checkoutNumberInvalid);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _numberError = null;
      _submitting = true;
    });
    try {
      final paymentId = await widget.submit(_channel, msisdn);
      unawaited(SharedPreferences.getInstance()
          .then((p) => p.setString(_lastMsisdnKey, msisdn)));
      if (!mounted) return;
      _wait(paymentId, msisdn);
    } on TalkyException catch (e) {
      if (!mounted) return;
      // Une demande attend déjà (double appui, écran rouvert) : on reprend
      // son attente plutôt que d'en refuser une seconde.
      final pending = (e.details?['paymentId'] as num?)?.toInt();
      if (e.code == 'PAYMENT_PENDING' && pending != null) {
        _wait(pending, msisdn);
      } else {
        afficherErreur(context, e, domaine: ErrorDomain.abonnement);
      }
    } catch (e) {
      if (mounted) afficherErreur(context, e, domaine: ErrorDomain.abonnement);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ── Attente ─────────────────────────────────────────────────────────

  void _wait(int paymentId, String? msisdn) {
    _stopWaiting();
    setState(() {
      _step = _Step.waiting;
      _paymentId = paymentId;
      _msisdn = msisdn;
      _startedAt = DateTime.now();
    });
    final service = context.read<EntitlementService>();
    _updates = service.paymentUpdates
        .where((u) => u.paymentId == paymentId && u.status.isFinal)
        .listen((_) => _check());
    // Filet : la socket peut être tombée pendant que l'utilisateur tapait son
    // code. Relire le statut coûte peu et ne conclut jamais à tort.
    _poll = Timer.periodic(_pollEvery, (_) => _check());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    unawaited(_check());
  }

  Future<void> _check() async {
    final id = _paymentId;
    if (id == null || _step != _Step.waiting || _checking) return;
    _checking = true;
    try {
      final api = context.read<TalkyApiClient>();
      final payment = PlusPayment.fromJson(await api.getPlusPayment(id));
      if (!mounted || !payment.status.isFinal) return;
      await _finish(payment);
    } catch (_) {
      // Silencieux : l'attente continue, le prochain passage réessaiera.
    } finally {
      _checking = false;
    }
  }

  Future<void> _finish(PlusPayment payment) async {
    _stopWaiting();
    if (payment.status == PaymentStatus.succeeded) {
      await widget.onSucceeded?.call(payment);
    }
    if (!mounted) return;
    setState(() {
      _result = payment;
      _step = payment.status == PaymentStatus.succeeded
          ? _Step.succeeded
          : _Step.failed;
    });
  }

  void _stopWaiting() {
    unawaited(_updates?.cancel());
    _updates = null;
    _poll?.cancel();
    _poll = null;
    _tick?.cancel();
    _tick = null;
  }

  void _retry() {
    final custom = widget.onRetry;
    if (custom != null) {
      custom();
      return;
    }
    setState(() {
      _step = _Step.form;
      _result = null;
      _paymentId = null;
    });
  }

  // ── Écrans ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final done = _step == _Step.succeeded;
    return PopScope(
      // Une fois payé, revenir en arrière ferme aussi l'écran d'origine.
      canPop: !done,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && done) Navigator.pop(context, true);
      },
      child: Scaffold(
        backgroundColor: context.semantic.surfaceMuted,
        appBar: AppBar(
          title: Text(done ? widget.doneTitle : widget.title),
          automaticallyImplyLeading: _step != _Step.succeeded,
        ),
        body: AnimatedSwitcher(
          duration: AppDurations.normal,
          child: switch (_step) {
            _Step.form => _form(context),
            _Step.waiting => _waiting(context),
            _Step.succeeded => KeyedSubtree(
                key: const ValueKey('succeeded'),
                child: widget.succeeded(context, _result!),
              ),
            _Step.failed => _failed(context),
          },
        ),
      ),
    );
  }

  Widget _form(BuildContext context) {
    final l10n = context.l10n;
    final options = widget.options;

    return Column(
      key: const ValueKey('form'),
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              widget.summary,
              AppSpacing.vGapXl,
              PlusSectionLabel(l10n.checkoutPayWith),
              for (final c in _channels) ...[
                _ChannelTile(
                  channel: c,
                  selected: c == _channel,
                  onTap: () => setState(() => _channel = c),
                ),
                AppSpacing.vGapSm,
              ],
              AppSpacing.vGapMd,
              PlusSectionLabel(l10n.checkoutNumber),
              TextField(
                controller: _number,
                keyboardType: TextInputType.phone,
                autofillHints: const [AutofillHints.telephoneNumber],
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9 +]')),
                  LengthLimitingTextInputFormatter(16),
                ],
                style: context.text.titleMedium?.copyWith(
                  fontFeatures: kTabularFigures,
                  letterSpacing: 0.5,
                ),
                decoration: InputDecoration(
                  // `prefixText` ne s'affiche qu'au focus, et réserve sa place
                  // avant : l'indicatif doit rester visible, champ vide ou non.
                  prefixIcon: Padding(
                    padding: const EdgeInsetsDirectional.only(
                        start: AppSpacing.md, end: AppSpacing.xs),
                    child: Text(
                      '+237',
                      style: context.text.titleMedium?.copyWith(
                        fontFeatures: kTabularFigures,
                        letterSpacing: 0.5,
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 0, minHeight: 0),
                  hintText: l10n.checkoutNumberHint,
                  errorText: _numberError,
                  filled: true,
                  fillColor: context.colors.surface,
                  border: const OutlineInputBorder(
                      borderRadius: AppRadius.brSm),
                ),
                onChanged: (_) {
                  if (_numberError != null) {
                    setState(() => _numberError = null);
                  }
                },
                onSubmitted: (_) => _submit(),
              ),
              if (options != null) ...[
                AppSpacing.vGapMd,
                options(context, _channel),
              ],
              if (widget.simulated) ...[
                AppSpacing.vGapMd,
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: context.semantic.warningContainer,
                    borderRadius: AppRadius.brSm,
                    border: Border.all(
                      color: context.semantic.warning.withValues(alpha: 0.6),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.science_outlined,
                          size: 18, color: context.semantic.warning),
                      AppSpacing.hGapSm,
                      Expanded(
                        child: Text(
                          l10n.checkoutSimulated,
                          style: context.text.bodySmall?.copyWith(
                            color: context.colors.onSurface,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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
          child: FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(AppSizes.buttonHeight),
              shape:
                  const RoundedRectangleBorder(borderRadius: AppRadius.brSm),
            ),
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.checkoutPay(widget.amount),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Widget _waiting(BuildContext context) {
    final l10n = context.l10n;
    final started = _startedAt ?? DateTime.now();
    final left = started.add(_requestLifetime).difference(DateTime.now());
    final mm = left.inMinutes.clamp(0, 99).toString();
    final ss = (left.inSeconds % 60).clamp(0, 59).toString().padLeft(2, '0');
    final number = _msisdn == null ? '' : _displayNumber(_msisdn!);

    return ListView(
      key: const ValueKey('waiting'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xxl,
        AppSpacing.xl,
        AppSpacing.xl,
      ),
      children: [
        Center(
          child: SizedBox.square(
            dimension: 92,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.square(
                  dimension: 92,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: context.colors.primary,
                    backgroundColor: context.semantic.brandContainer,
                  ),
                ),
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: context.semantic.brandContainer,
                  ),
                  child: Icon(Icons.phone_iphone_rounded,
                      size: 34, color: context.colors.primary),
                ),
              ],
            ),
          ),
        ),
        AppSpacing.vGapXl,
        Text(
          l10n.checkoutWaitingTitle,
          textAlign: TextAlign.center,
          style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        AppSpacing.vGapSm,
        Text(
          l10n.checkoutWaitingBody(_channel.brand, widget.amount),
          textAlign: TextAlign.center,
          style: context.text.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        if (left > Duration.zero) ...[
          AppSpacing.vGapSm,
          Text(
            l10n.checkoutExpiresIn('$mm:$ss'),
            textAlign: TextAlign.center,
            style: context.text.labelMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
              fontFeatures: kTabularFigures,
            ),
          ),
        ],
        AppSpacing.vGapXxl,
        Material(
          color: context.colors.surface,
          borderRadius: AppRadius.brMd,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              children: [
                PlusTimelineStep(
                  state: PlusStepState.done,
                  title: l10n.checkoutStepSent,
                  // Écran rouvert sur une demande en cours : le numéro débité
                  // n'est plus connu ici.
                  subtitle: number.isEmpty ? '' : l10n.checkoutStepSentTo(number),
                ),
                PlusTimelineStep(
                  state: PlusStepState.current,
                  title: l10n.checkoutStepConfirm,
                  subtitle: l10n.checkoutStepPending,
                ),
                PlusTimelineStep(
                  state: PlusStepState.todo,
                  title: widget.activatedStep,
                  subtitle: l10n.checkoutStepActivatedHint(_channel.brand),
                  last: true,
                ),
              ],
            ),
          ),
        ),
        AppSpacing.vGapXl,
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(AppSizes.buttonHeight),
            shape: const RoundedRectangleBorder(borderRadius: AppRadius.brSm),
          ),
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.checkoutLeave),
        ),
        AppSpacing.vGapSm,
        Text(
          widget.leaveHint,
          textAlign: TextAlign.center,
          style: context.text.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _failed(BuildContext context) {
    final l10n = context.l10n;
    final result = _result;
    final body = switch (result?.failureCode) {
      'INSUFFICIENT_FUNDS' => l10n.checkoutFailedInsufficient,
      'USER_DECLINED' => l10n.checkoutFailedDeclined,
      'TIMEOUT' => l10n.checkoutFailedTimeout,
      _ => result?.status == PaymentStatus.expired
          ? l10n.checkoutFailedTimeout
          : l10n.checkoutFailedGeneric,
    };
    return CheckoutOutcome(
      key: const ValueKey('failed'),
      icon: Icons.close_rounded,
      iconColor: context.colors.error,
      disc: context.colors.errorContainer,
      title: l10n.checkoutFailedTitle,
      body: body,
      primary: l10n.retry,
      onPrimary: _retry,
      secondary: MaterialLocalizations.of(context).closeButtonLabel,
      onSecondary: () => Navigator.pop(context, false),
    );
  }

  /// `237699123400` → `+237 6 99 12 34 00`.
  static String _displayNumber(String msisdn) {
    if (!msisdn.startsWith('237') || msisdn.length != 12) return '+$msisdn';
    final n = msisdn.substring(3);
    return '+237 ${n[0]} ${n.substring(1, 3)} ${n.substring(3, 5)} '
        '${n.substring(5, 7)} ${n.substring(7)}';
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.selected,
    required this.onTap,
  });

  final PaymentChannel channel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Couleurs de marque des opérateurs : identiques en clair et en sombre.
    final (logo, bg, fg) = switch (channel) {
      PaymentChannel.orangeMoney =>
        ('OM', const Color(0xFFFF7900), const Color(0xFF000000)),
      PaymentChannel.mtnMomo =>
        ('MTN', const Color(0xFFFFCB05), const Color(0xFF1A1A1A)),
    };
    return Material(
      color: context.colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.brSm,
        side: BorderSide(
          color: selected
              ? context.colors.primary
              : context.colors.outlineVariant,
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
              Container(
                width: 40,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  logo,
                  style: TextStyle(
                    color: fg,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              AppSpacing.hGapMd,
              Expanded(
                child: Text(
                  channel.brand,
                  style: context.text.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              PlusChoiceDot(selected: selected),
            ],
          ),
        ),
      ),
    );
  }
}

/// Écran de conclusion : pastille, titre, texte, un ou deux boutons.
class CheckoutOutcome extends StatelessWidget {
  const CheckoutOutcome({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.disc,
    required this.title,
    required this.body,
    required this.primary,
    required this.onPrimary,
    this.extra,
    this.secondary,
    this.onSecondary,
  });

  final IconData icon;
  final Color iconColor;
  final Color disc;
  final String title;
  final String body;
  final Widget? extra;
  final String primary;
  final VoidCallback onPrimary;
  final String? secondary;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl,
              AppSpacing.xxl * 1.5,
              AppSpacing.xl,
              AppSpacing.xl,
            ),
            children: [
              Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: disc),
                  child: Icon(icon, size: 40, color: iconColor),
                ),
              ),
              AppSpacing.vGapXl,
              Text(
                title,
                textAlign: TextAlign.center,
                style: context.text.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (body.isNotEmpty) ...[
                AppSpacing.vGapSm,
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ],
              if (extra != null) ...[AppSpacing.vGapXl, extra!],
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
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(AppSizes.buttonHeight),
                  shape: const RoundedRectangleBorder(
                      borderRadius: AppRadius.brSm),
                ),
                onPressed: onPrimary,
                child: Text(primary,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              if (secondary != null)
                TextButton(onPressed: onSecondary, child: Text(secondary!)),
            ],
          ),
        ),
      ],
    );
  }
}
