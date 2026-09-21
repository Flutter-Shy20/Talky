/// Dossier de vérification d'identité, tel que `GET /api/verification` le
/// décrit (Alanya-Backend, src/controllers/verificationController.js).
library;

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// Avancement du dossier.
enum VerificationRequestStatus {
  pending('pending'),
  documentRequested('document_requested'),
  approved('approved'),
  refused('refused'),
  cancelled('cancelled'),
  revoked('revoked');

  const VerificationRequestStatus(this.wire);
  final String wire;

  static VerificationRequestStatus? fromWire(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    return null;
  }

  /// Un dossier ouvert : on attend l'administration, ou une pièce.
  bool get isOpen => this == pending || this == documentRequested;
}

/// Type de pièce (`verification_document.doc_type`).
abstract final class VerificationDocType {
  static const identity = 1;
  static const selfie = 4;
}

class VerificationRequest {
  const VerificationRequest({
    required this.id,
    required this.status,
    this.claimedName,
    this.nameAtApproval,
    this.nameChanged = false,
    this.reason,
    this.createdAt,
    this.decidedAt,
  });

  final int id;
  final VerificationRequestStatus status;
  final String? claimedName;
  final String? nameAtApproval;

  /// Approuvé, mais le nom affiché a changé depuis : la coche attend un
  /// nouvel examen.
  final bool nameChanged;

  /// Motif du refus, de la révocation ou de la pièce demandée.
  final String? reason;
  final DateTime? createdAt;
  final DateTime? decidedAt;

  factory VerificationRequest.fromJson(Map<String, dynamic> json) =>
      VerificationRequest(
        id: (json['id'] as num?)?.toInt() ?? 0,
        status: VerificationRequestStatus.fromWire(json['status']) ??
            VerificationRequestStatus.pending,
        claimedName: json['claimedName'] as String?,
        nameAtApproval: json['nameAtApproval'] as String?,
        nameChanged: json['nameChanged'] == true,
        reason: json['reason'] as String?,
        createdAt: _date(json['createdAt']),
        decidedAt: _date(json['decidedAt']),
      );
}

class VerificationDocumentInfo {
  const VerificationDocumentInfo({
    required this.id,
    required this.docType,
    this.purged = false,
  });

  final int id;
  final int docType;
  final bool purged;

  factory VerificationDocumentInfo.fromJson(Map<String, dynamic> json) =>
      VerificationDocumentInfo(
        id: (json['id'] as num?)?.toInt() ?? 0,
        docType: (json['docType'] as num?)?.toInt() ?? 0,
        purged: json['purged'] == true,
      );
}

/// Ce que l'écran « Obtenir la coche » affiche, en un appel.
class VerificationState {
  const VerificationState({
    this.available = false,
    this.currentName = '',
    this.status = 0,
    this.until,
    this.request,
    this.documents = const [],
  });

  /// Faux tant que le coffre à pièces n'est pas configuré côté serveur.
  final bool available;
  final String currentName;

  /// La coche (`users.verification_status`) : 0 non demandée … 5 expirée.
  final int status;
  final DateTime? until;
  final VerificationRequest? request;
  final List<VerificationDocumentInfo> documents;

  bool get isVerified => status == 2;

  /// Identité vérifiée, mais la coche est en pause faute d'abonnement.
  bool get isPaused => status == 5;

  /// Déposer (ou redéposer) est possible : aucun dossier ouvert, et pas
  /// d'identité déjà vérifiée sous le nom actuel.
  bool get canSubmit {
    final r = request;
    if (r == null) return true;
    if (r.status.isOpen) return false;
    if (r.status == VerificationRequestStatus.approved) return r.nameChanged;
    return true;
  }

  factory VerificationState.fromJson(Map<String, dynamic> json) {
    final v = json['verification'];
    final r = json['request'];
    return VerificationState(
      available: json['available'] == true,
      currentName: (json['currentName'] ?? '').toString(),
      status: v is Map ? ((v['status'] as num?)?.toInt() ?? 0) : 0,
      until: v is Map ? _date(v['until']) : null,
      request: r is Map
          ? VerificationRequest.fromJson(Map<String, dynamic>.from(r))
          : null,
      documents: [
        for (final d in (json['documents'] as List? ?? const []))
          if (d is Map)
            VerificationDocumentInfo.fromJson(Map<String, dynamic>.from(d)),
      ],
    );
  }
}
