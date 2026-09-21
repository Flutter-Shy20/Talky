/// Offre, paiements et historique Alanya Plus, tels que le serveur les décrit.
///
/// Réponses de `GET /billing/offer`, `POST /billing/checkout`,
/// `GET /billing/payments/:id` et `GET /billing/history` (Alanya-Backend,
/// src/controllers/billingController.js). Aucune règle métier ici : prix et
/// droits viennent du serveur. Seul l'argument de prix (« soit 167 F par
/// mois », « 4 mois offerts ») se calcule — comme dans l'administration
/// (alanya-admin, lib/plan-pricing.ts), pour ne jamais pouvoir mentir.
library;

import 'entitlements.dart';

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

String? _nonEmpty(String? v) => v != null && v.trim().isNotEmpty ? v : null;

Map<String, String> _i18nMap(Object? v) {
  if (v is String) return {'fr': v};
  if (v is! Map) return const {};
  return {
    for (final e in v.entries)
      if (e.value is String) '${e.key}': e.value as String,
  };
}

/// Texte d'un champ multilingue `{fr, en, zh}` : la langue demandée, sinon le
/// français (langue de saisie de l'administration), sinon la première non vide.
String pickI18n(Map<String, String> texts, String lang) =>
    _nonEmpty(texts[lang]) ??
    _nonEmpty(texts['fr']) ??
    texts.values.firstWhere((v) => v.trim().isNotEmpty, orElse: () => '');

/// Un plan de l'offre (`plus_mensuel`, `plus_annuel`…), modifiable côté
/// administration sans nouvelle version de l'application.
class PlusPlan {
  const PlusPlan({
    required this.code,
    this.names = const {},
    required this.durationMonths,
    required this.price,
    this.currency = 'XAF',
    this.featured = false,
    this.features = const [],
  });

  final String code;
  final Map<String, String> names;
  final int durationMonths;

  /// En francs CFA, sans sous-unité.
  final int price;
  final String currency;

  /// Mis en avant et présélectionné (l'annuel, aujourd'hui).
  final bool featured;

  /// Codes des fonctionnalités incluses.
  final List<String> features;

  String nameFor(String lang) => pickI18n(names, lang);

  /// Prix ramené au mois, arrondi à l'entier.
  int get monthlyEquivalent =>
      durationMonths <= 0 ? price : (price / durationMonths).round();

  /// Mois « offerts » par rapport au plan mensuel [reference] : ce que la
  /// même durée coûterait au mois, moins le prix du plan, en mois entiers.
  int monthsOffered(PlusPlan? reference) {
    if (reference == null ||
        reference.durationMonths != 1 ||
        durationMonths <= 1) {
      return 0;
    }
    final monthly = reference.price;
    if (monthly <= 0) return 0;
    final saving = monthly * durationMonths - price;
    return saving > 0 ? saving ~/ monthly : 0;
  }

  factory PlusPlan.fromJson(Map<String, dynamic> json) => PlusPlan(
        code: '${json['code'] ?? ''}',
        names: _i18nMap(json['name']),
        durationMonths: _int(json['durationMonths']),
        price: _int(json['price']),
        currency: '${json['currency'] ?? 'XAF'}',
        featured: json['featured'] == true,
        features: [
          for (final f in (json['features'] as List? ?? const [])) '$f',
        ],
      );
}

/// Une fonctionnalité payante, décrite par le catalogue serveur.
class PlusOfferFeature {
  const PlusOfferFeature({
    required this.code,
    this.names = const {},
    this.descriptions = const {},
  });

  final String code;
  final Map<String, String> names;
  final Map<String, String> descriptions;

  PlusFeature? get feature {
    for (final f in PlusFeature.values) {
      if (f.code == code) return f;
    }
    return null;
  }

  String nameFor(String lang) => pickI18n(names, lang);
  String descriptionFor(String lang) => pickI18n(descriptions, lang);

  factory PlusOfferFeature.fromJson(Map<String, dynamic> json) =>
      PlusOfferFeature(
        code: '${json['code'] ?? ''}',
        names: _i18nMap(json['name']),
        descriptions: _i18nMap(json['description']),
      );
}

/// Moyen de paiement mobile money.
enum PaymentChannel {
  orangeMoney('orange_money', 'Orange Money'),
  mtnMomo('mtn_momo', 'MTN Mobile Money');

  const PaymentChannel(this.wire, this.brand);

  final String wire;

  /// Nom de marque : il ne se traduit pas.
  final String brand;

  static PaymentChannel? fromWire(Object? v) {
    for (final c in values) {
      if (c.wire == v) return c;
    }
    return null;
  }
}

/// Le fournisseur actif. `simulated` tant que l'agrégateur n'est pas branché :
/// aucun argent n'est débité, et l'écran de paiement le dit.
class PaymentProviderInfo {
  const PaymentProviderInfo({
    required this.name,
    this.channels = const [],
    this.simulated = false,
  });

  final String name;
  final List<PaymentChannel> channels;
  final bool simulated;

  factory PaymentProviderInfo.fromJson(Map<String, dynamic> json) =>
      PaymentProviderInfo(
        name: '${json['name'] ?? ''}',
        channels: [
          for (final c in (json['channels'] as List? ?? const []))
            if (PaymentChannel.fromWire(c) case final PaymentChannel ch) ch,
        ],
        simulated: json['simulated'] == true,
      );
}

/// Tout ce que l'écran d'offre affiche, en un appel.
class PlusOffer {
  const PlusOffer({
    this.phase = PlusPhase.free,
    this.graceUntil,
    this.purchasable = false,
    this.plans = const [],
    this.features = const [],
    this.provider,
    this.entitlements = Entitlements.unrestricted,
  });

  final PlusPhase phase;
  final DateTime? graceUntil;

  /// Faux en phase gratuite, ou sans fournisseur : rien à vendre.
  final bool purchasable;
  final List<PlusPlan> plans;
  final List<PlusOfferFeature> features;
  final PaymentProviderInfo? provider;
  final Entitlements entitlements;

  /// Le mensuel, base de comparaison des autres durées.
  PlusPlan? get reference {
    for (final p in plans) {
      if (p.durationMonths == 1) return p;
    }
    return null;
  }

  /// Le plan présélectionné : celui mis en avant, sinon le premier.
  PlusPlan? get defaultPlan {
    for (final p in plans) {
      if (p.featured) return p;
    }
    return plans.isEmpty ? null : plans.first;
  }

  /// « À partir de 167 F / mois » : le plus petit prix mensuel de l'offre.
  int? get lowestMonthly {
    int? best;
    for (final p in plans) {
      final m = p.monthlyEquivalent;
      if (best == null || m < best) best = m;
    }
    return best;
  }

  PlusPlan? planByCode(String? code) {
    for (final p in plans) {
      if (p.code == code) return p;
    }
    return null;
  }

  factory PlusOffer.fromJson(Map<String, dynamic> json) {
    final entitlements = json['entitlements'];
    final provider = json['provider'];
    return PlusOffer(
      phase: Entitlements.fromJson({'phase': json['phase']}).phase,
      graceUntil: _date(json['graceUntil']),
      purchasable: json['purchasable'] == true,
      plans: [
        for (final p in (json['plans'] as List? ?? const []))
          if (p is Map) PlusPlan.fromJson(Map<String, dynamic>.from(p)),
      ],
      features: [
        for (final f in (json['features'] as List? ?? const []))
          if (f is Map) PlusOfferFeature.fromJson(Map<String, dynamic>.from(f)),
      ],
      provider: provider is Map
          ? PaymentProviderInfo.fromJson(Map<String, dynamic>.from(provider))
          : null,
      entitlements: entitlements is Map
          ? Entitlements.fromJson(Map<String, dynamic>.from(entitlements))
          : Entitlements.unrestricted,
    );
  }
}

/// État d'un paiement. Seul le fournisseur le fait avancer.
enum PaymentStatus {
  created,
  pending,
  succeeded,
  failed,
  expired,
  refunded;

  /// Plus rien ne bougera : l'écran d'attente peut conclure.
  bool get isFinal =>
      this == succeeded || this == failed || this == expired || this == refunded;

  static PaymentStatus? fromWire(Object? v) {
    for (final s in values) {
      if (s.name == v) return s;
    }
    return null;
  }
}

/// Un paiement du compte (`GET /billing/payments/:id`, historique).
class PlusPayment {
  const PlusPayment({
    required this.id,
    required this.status,
    this.plan,
    this.amount = 0,
    this.currency = 'XAF',
    this.channel,
    this.failureCode,
    this.createdAt,
    this.confirmedAt,
  });

  final int id;
  final PaymentStatus status;
  final String? plan;
  final int amount;
  final String currency;
  final PaymentChannel? channel;

  /// `INSUFFICIENT_FUNDS`, `USER_DECLINED`, `TIMEOUT`…
  final String? failureCode;
  final DateTime? createdAt;
  final DateTime? confirmedAt;

  factory PlusPayment.fromJson(Map<String, dynamic> json) => PlusPayment(
        id: _int(json['id']),
        status: PaymentStatus.fromWire(json['status']) ?? PaymentStatus.pending,
        plan: json['plan'] as String?,
        amount: _int(json['amount']),
        currency: '${json['currency'] ?? 'XAF'}',
        channel: PaymentChannel.fromWire(json['channel']),
        failureCode: json['failureCode'] as String?,
        createdAt: _date(json['createdAt']),
        confirmedAt: _date(json['confirmedAt']),
      );
}

/// Réponse de `POST /billing/checkout` : une demande, jamais un paiement fait.
class CheckoutResult {
  const CheckoutResult({
    required this.paymentId,
    this.status = PaymentStatus.pending,
    this.amount = 0,
    this.currency = 'XAF',
  });

  final int paymentId;
  final PaymentStatus status;
  final int amount;
  final String currency;

  factory CheckoutResult.fromJson(Map<String, dynamic> json) => CheckoutResult(
        paymentId: _int(json['paymentId']),
        status: PaymentStatus.fromWire(json['status']) ?? PaymentStatus.pending,
        amount: _int(json['amount']),
        currency: '${json['currency'] ?? 'XAF'}',
      );
}

/// Numéro mobile money au format du serveur (`2376XXXXXXXX`), ou null.
///
/// Même règle que `normalizeMsisdn` (Alanya-Backend,
/// src/services/payments/paymentRules.js). Vérifier ici épargne un
/// aller-retour pour une faute de frappe ; le serveur tranche de toute façon.
String? normalizeMsisdn(String raw) {
  var digits = raw.replaceAll(RegExp(r'[\s().-]'), '');
  if (digits.startsWith('+')) digits = digits.substring(1);
  if (digits.startsWith('00')) digits = digits.substring(2);
  if (!RegExp(r'^\d{8,15}$').hasMatch(digits)) return null;
  final local = RegExp(r'^6\d{8}$');
  if (digits.startsWith('237')) {
    return local.hasMatch(digits.substring(3)) ? digits : null;
  }
  if (local.hasMatch(digits)) return '237$digits';
  return digits.length >= 10 ? digits : null;
}

/// Périodes et paiements du compte, les plus récents d'abord.
class PlusHistory {
  const PlusHistory({this.periods = const [], this.payments = const []});

  final List<PlusPeriod> periods;
  final List<PlusPayment> payments;

  factory PlusHistory.fromJson(Map<String, dynamic> json) => PlusHistory(
        periods: [
          for (final p in (json['periods'] as List? ?? const []))
            if (p is Map) PlusPeriod.fromJson(Map<String, dynamic>.from(p)),
        ],
        payments: [
          for (final p in (json['payments'] as List? ?? const []))
            if (p is Map) PlusPayment.fromJson(Map<String, dynamic>.from(p)),
        ],
      );
}
