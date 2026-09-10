/// Droits d'accès Alanya Plus, tels que le serveur les calcule.
///
/// Même charge utile que `entitlements` dans `/auth/me` et que
/// `GET /billing/me` (Alanya-Backend, src/services/billing/rules.js). Le
/// téléphone ne recalcule jamais la règle : il lit ce qu'on lui donne.
library;

/// Fonctionnalités de l'offre. Le code est celui du catalogue serveur
/// (table `feature`, migration 080).
enum PlusFeature {
  translation('translation'),
  backup('backup'),
  trustedTrips('trusted_trips'),
  listRingtones('list_ringtones'),
  style('style'),
  verifiedBadge('verified_badge');

  const PlusFeature(this.code);
  final String code;

  /// Depuis le code serveur (`feature` d'un refus `SUBSCRIPTION_REQUIRED`).
  static PlusFeature? fromCode(Object? code) {
    for (final f in values) {
      if (f.code == code) return f;
    }
    return null;
  }
}

/// Phase du payant : tout gratuit, grâce annoncée, ou réservé aux abonnés.
enum PlusPhase { free, grace, paid }

PlusPhase _phase(Object? v) => switch (v) {
      'grace' => PlusPhase.grace,
      'paid' => PlusPhase.paid,
      _ => PlusPhase.free,
    };

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// Une période d'abonnement (en cours, ou à venir si payée pendant la grâce).
class PlusPeriod {
  const PlusPeriod({
    this.plan,
    this.startsAt,
    this.endsAt,
    this.source = 0,
    this.autoRenew = false,
  });

  /// Code du plan (`plus_mensuel`, `plus_annuel`…).
  final String? plan;
  final DateTime? startsAt;

  /// Fin de la chaîne de périodes : un renouvellement anticipé la repousse.
  final DateTime? endsAt;

  /// 0 paiement, 1 essai, 2 offert, 3 compensation.
  final int source;
  final bool autoRenew;

  factory PlusPeriod.fromJson(Map<String, dynamic> json) => PlusPeriod(
        plan: json['plan'] as String?,
        startsAt: _date(json['startsAt']),
        endsAt: _date(json['endsAt']),
        source: (json['source'] as num?)?.toInt() ?? 0,
        autoRenew: json['autoRenew'] == true,
      );

  Map<String, dynamic> toJson() => {
        'plan': plan,
        'startsAt': startsAt?.toUtc().toIso8601String(),
        'endsAt': endsAt?.toUtc().toIso8601String(),
        'source': source,
        'autoRenew': autoRenew,
      };
}

class Entitlements {
  const Entitlements({
    required this.known,
    this.phase = PlusPhase.free,
    this.graceUntil,
    this.period,
    this.upcoming,
    this.exempt = false,
    this.features = const {},
    this.validUntil,
    this.lapsedAt,
  });

  /// Serveur antérieur à l'abonnement, ou droits indisponibles : tout est
  /// permis. L'app ne ferme jamais une fonctionnalité faute de réponse.
  static const unrestricted = Entitlements(known: false);

  /// Faux tant que le serveur n'a pas envoyé de droits.
  final bool known;
  final PlusPhase phase;
  final DateTime? graceUntil;
  final PlusPeriod? period;
  final PlusPeriod? upcoming;

  /// Équipe et compte officiel : jamais soumis à l'offre.
  final bool exempt;
  final Map<String, bool> features;

  /// Au-delà, redemander les droits. Ne ferme rien à lui seul : le serveur
  /// fait respecter ce qu'il voit, et un droit en cache vaut mieux qu'un
  /// verrou posé faute de réseau.
  final DateTime? validUntil;

  /// Fin du dernier abonnement, quand il est terminé et qu'aucun n'a pris le
  /// relais. Nul pour qui n'a jamais été abonné.
  final DateTime? lapsedAt;

  /// Une fonctionnalité inconnue du serveur n'est pas verrouillée.
  bool has(PlusFeature feature) => !known || (features[feature.code] ?? true);

  bool get isSubscribed => period != null;

  bool isStale(DateTime now) =>
      known && validUntil != null && now.isAfter(validUntil!);

  factory Entitlements.fromJson(Map<String, dynamic>? json) {
    if (json == null) return unrestricted;
    final raw = json['features'];
    final features = <String, bool>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is bool) features['$k'] = v;
        if (v is num) features['$k'] = v != 0;
      });
    }
    Map<String, dynamic>? map(Object? v) =>
        v is Map ? Map<String, dynamic>.from(v) : null;
    final period = map(json['period']);
    final upcoming = map(json['upcoming']);
    return Entitlements(
      known: true,
      phase: _phase(json['phase']),
      graceUntil: _date(json['graceUntil']),
      period: period == null ? null : PlusPeriod.fromJson(period),
      upcoming: upcoming == null ? null : PlusPeriod.fromJson(upcoming),
      exempt: json['exempt'] == true,
      features: features,
      validUntil: _date(json['validUntil']),
      lapsedAt: _date(json['lapsedAt']),
    );
  }

  /// Forme serveur, pour le cache local : relue par [Entitlements.fromJson].
  Map<String, dynamic> toJson() => {
        'phase': phase.name,
        'graceUntil': graceUntil?.toUtc().toIso8601String(),
        'period': period?.toJson(),
        'upcoming': upcoming?.toJson(),
        'exempt': exempt,
        'features': features,
        'validUntil': validUntil?.toUtc().toIso8601String(),
        'lapsedAt': lapsedAt?.toUtc().toIso8601String(),
      };
}
