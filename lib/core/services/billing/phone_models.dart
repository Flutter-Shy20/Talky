/// Le numéro choisi — un numéro Alanya à 8 chiffres acheté hors abonnement —
/// tel que le serveur le décrit.
///
/// Réponses de `GET /alanya-phone/offer`, `GET /alanya-phone/check`,
/// `POST /alanya-phone/hold` (Alanya-Backend, src/services/alanyaPhonePurchase.js).
/// Aucune règle ici : ce qui est à vendre, le prix et la durée de la mise de
/// côté viennent du serveur.
library;

import 'billing_models.dart';

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

int? _intOrNull(Object? v) => v == null ? null : _int(v);

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// Pourquoi un numéro n'est pas à vendre.
enum PhoneRefusal {
  /// C'est déjà le numéro du compte.
  same('same'),

  /// Porté par un autre compte.
  taken('taken'),

  /// Mis de côté par Alanya.
  setAside('set_aside'),

  /// Retenu, ou en cours de paiement, par quelqu'un d'autre : cela passera.
  held('held'),

  /// Quitté récemment par son titulaire : pas encore disponible.
  quarantine('quarantine');

  const PhoneRefusal(this.wire);

  final String wire;

  static PhoneRefusal? fromWire(Object? v) {
    for (final r in values) {
      if (r.wire == v) return r;
    }
    return null;
  }
}

enum PhoneOrderStatus {
  held('held'),
  paying('paying'),
  applied('applied'),
  abandoned('abandoned'),
  credit('credit');

  const PhoneOrderStatus(this.wire);

  final String wire;

  static PhoneOrderStatus? fromWire(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    return null;
  }
}

/// Une commande : le numéro retenu au nom du compte, puis en paiement.
class PhoneOrder {
  const PhoneOrder({
    required this.id,
    required this.phone,
    required this.status,
    this.heldUntil,
    this.paymentId,
  });

  final int id;
  final String phone;
  final PhoneOrderStatus status;

  /// Fin de la mise de côté. Sans objet une fois le paiement demandé : le
  /// numéro reste alors retenu jusqu'à la réponse de l'opérateur.
  final DateTime? heldUntil;
  final int? paymentId;

  factory PhoneOrder.fromJson(Map<String, dynamic> json) => PhoneOrder(
        id: _int(json['id']),
        phone: '${json['phone'] ?? ''}',
        status: PhoneOrderStatus.fromWire(json['status']) ?? PhoneOrderStatus.held,
        heldUntil: _date(json['heldUntil']),
        paymentId: _intOrNull(json['paymentId']),
      );

  static PhoneOrder? tryParse(Object? v) =>
      v is Map ? PhoneOrder.fromJson(Map<String, dynamic>.from(v)) : null;
}

/// Tout ce que l'écran du numéro affiche, en un appel.
class PhoneOffer {
  const PhoneOffer({
    this.purchasable = false,
    this.price = 0,
    this.currency = 'XAF',
    this.holdMinutes = 15,
    this.provider,
    this.currentPhone = '',
    this.order,
    this.credit = false,
  });

  /// Faux hors de portée de ce compte (fournisseur simulé en production,
  /// compte officiel) : l'entrée n'est pas proposée.
  final bool purchasable;
  final int price;
  final String currency;
  final int holdMinutes;
  final PaymentProviderInfo? provider;
  final String currentPhone;

  /// La commande à reprendre : retenue, ou en cours de paiement.
  final PhoneOrder? order;

  /// Un changement déjà payé attend son numéro : le prochain numéro choisi
  /// est posé sans nouveau paiement.
  final bool credit;

  static const unavailable = PhoneOffer();

  factory PhoneOffer.fromJson(Map<String, dynamic> json) {
    final provider = json['provider'];
    return PhoneOffer(
      purchasable: json['purchasable'] == true,
      price: _int(json['price']),
      currency: '${json['currency'] ?? 'XAF'}',
      holdMinutes: _int(json['holdMinutes'] ?? 15),
      provider: provider is Map
          ? PaymentProviderInfo.fromJson(Map<String, dynamic>.from(provider))
          : null,
      currentPhone: '${json['currentPhone'] ?? ''}',
      order: PhoneOrder.tryParse(json['order']),
      credit: json['credit'] == true,
    );
  }
}

/// Réponse de `GET /alanya-phone/check`.
class PhoneAvailability {
  const PhoneAvailability({
    required this.phone,
    required this.available,
    this.reason,
  });

  final String phone;
  final bool available;
  final PhoneRefusal? reason;

  factory PhoneAvailability.fromJson(Map<String, dynamic> json) =>
      PhoneAvailability(
        phone: '${json['phone'] ?? ''}',
        available: json['available'] == true,
        reason: PhoneRefusal.fromWire(json['reason']),
      );
}

/// Réponse de `POST /alanya-phone/hold` : une mise de côté, ou — s'il restait
/// un changement payé — le numéro déjà posé.
class PhoneHoldResult {
  const PhoneHoldResult({
    this.order,
    this.applied = false,
    this.credit = false,
    this.phone,
  });

  final PhoneOrder? order;

  /// Posé tout de suite, sans paiement (crédit utilisé).
  final bool applied;

  /// Posé nulle part : le numéro a été pris dans l'instant, le crédit reste.
  final bool credit;
  final String? phone;

  factory PhoneHoldResult.fromJson(Map<String, dynamic> json) =>
      PhoneHoldResult(
        order: PhoneOrder.tryParse(json['order']),
        applied: json['applied'] == true,
        credit: json['credit'] == true,
        phone: json['phone'] as String?,
      );
}
