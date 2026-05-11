/// Représente un participant d'une conversation.
class Participant {
  final int alanyaId;
  final String nom;
  final String? pseudo;
  final String? avatarUrl;
  final bool isOnline;
  final DateTime? lastSeen;

  Participant({
    required this.alanyaId,
    required this.nom,
    this.pseudo,
    this.avatarUrl,
    required this.isOnline,
    this.lastSeen,
  });

  factory Participant.fromJson(Map<String, dynamic> json) {
    return Participant(
      alanyaId: json['alanyaID'] ?? 0,
      nom: json['nom'] ?? '',
      pseudo: json['pseudo'],
      avatarUrl: json['avatar_url'],
      isOnline: (json['is_online'] ?? 0) == 1,
      lastSeen: json['last_seen'] != null ? DateTime.tryParse(json['last_seen']) : null,
    );
  }

  /// Le nom à afficher : pseudo en priorité, sinon nom complet.
  String get displayName => (pseudo != null && pseudo!.isNotEmpty) ? pseudo! : nom;
}

/// Représente une conversation telle que renvoyée par GET /api/conversations
class Conversation {
  final int id;
  final bool isGroup;
  final String? groupName;
  final String? groupPhoto;
  final String? lastMessage;
  final DateTime? lastMessageAt;
  final int unreadCount;
  final List<Participant> participants;

  Conversation({
    required this.id,
    required this.isGroup,
    this.groupName,
    this.groupPhoto,
    this.lastMessage,
    this.lastMessageAt,
    required this.unreadCount,
    required this.participants,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final parts = (json['participants'] as List<dynamic>? ?? [])
        .map((p) => Participant.fromJson(Map<String, dynamic>.from(p)))
        .toList();

    return Conversation(
      id: json['conversID'] ?? 0,
      isGroup: (json['isGroup'] ?? 0) == 1,
      groupName: json['GroupName'],
      groupPhoto: json['groupPhoto'],
      lastMessage: json['lastMessage'],
      lastMessageAt: json['lastMessageAt'] != null
          ? DateTime.tryParse(json['lastMessageAt'])
          : null,
      unreadCount: json['unreadCount'] ?? 0,
      participants: parts,
    );
  }

  /// Renvoie le nom à afficher pour cette conversation.
  /// - Groupe : GroupName
  /// - 1-to-1 : pseudo/nom de l'autre participant (pas currentUserId)
  String displayName(int currentUserId) {
    if (isGroup) return groupName ?? 'Groupe';
    final other = _otherParticipant(currentUserId);
    return other?.displayName ?? 'Conversation';
  }

  /// Renvoie l'avatar de l'interlocuteur (null pour les groupes ou si absent).
  String? displayAvatar(int currentUserId) {
    if (isGroup) return groupPhoto;
    return _otherParticipant(currentUserId)?.avatarUrl;
  }

  /// L'autre participant (pour une conversation 1-to-1).
  Participant? _otherParticipant(int currentUserId) {
    try {
      return participants.firstWhere((p) => p.alanyaId != currentUserId);
    } catch (_) {
      return participants.isNotEmpty ? participants.first : null;
    }
  }

  /// Est-ce que l'interlocuteur est en ligne ? (pour les 1-to-1)
  bool isOtherOnline(int currentUserId) {
    return _otherParticipant(currentUserId)?.isOnline ?? false;
  }

  /// ID de l'interlocuteur (pour les 1-to-1), utilisé pour écouter la présence.
  int? otherParticipantId(int currentUserId) {
    return _otherParticipant(currentUserId)?.alanyaId;
  }
}
