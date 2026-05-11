/// Types de messages — correspondent au champ `type` en base de données.
class MessageType {
  static const int text  = 0;
  static const int image = 1;
  static const int video = 2;
  static const int audio = 3;
  static const int file  = 4;
}

/// Représente un message tel que renvoyé par l'API ou reçu via socket.
class Message {
  final int id;
  final int senderId;
  final int conversationId;
  final String? content;
  final DateTime sentAt;
  final int status;       // 1=envoyé, 2=distribué, 3=lu
  final int type;         // Voir MessageType
  final String? mediaUrl;
  final String? mediaName;
  final int? mediaDuration; // durée en secondes (pour audio/vidéo)
  final String? senderNom;
  final String? senderPseudo;
  final String? senderAvatar;

  Message({
    required this.id,
    required this.senderId,
    required this.conversationId,
    this.content,
    required this.sentAt,
    required this.status,
    this.type = MessageType.text,
    this.mediaUrl,
    this.mediaName,
    this.mediaDuration,
    this.senderNom,
    this.senderPseudo,
    this.senderAvatar,
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['msgID'] ?? 0,
      senderId: json['senderID'] ?? 0,
      conversationId: json['conversationID'] ?? 0,
      content: json['content'],
      sentAt: json['sendAt'] != null
          ? DateTime.tryParse(json['sendAt']) ?? DateTime.now()
          : DateTime.now(),
      status: json['status'] ?? 1,
      type: json['type'] ?? MessageType.text,
      mediaUrl: json['mediaUrl'],
      mediaName: json['mediaName'],
      mediaDuration: json['mediaDuration'],
      senderNom: json['sender_nom'],
      senderPseudo: json['sender_pseudo'],
      senderAvatar: json['sender_avatar'],
    );
  }

  /// Crée une copie du message avec certains champs modifiés.
  Message copyWith({
    int? status,
    String? mediaUrl,
  }) {
    return Message(
      id: id,
      senderId: senderId,
      conversationId: conversationId,
      content: content,
      sentAt: sentAt,
      status: status ?? this.status,
      type: type,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      mediaName: mediaName,
      mediaDuration: mediaDuration,
      senderNom: senderNom,
      senderPseudo: senderPseudo,
      senderAvatar: senderAvatar,
    );
  }

  String get displayName => senderPseudo ?? senderNom ?? 'Inconnu';

  bool get isMedia => type != MessageType.text;
  bool get isImage => type == MessageType.image;
  bool get isAudio => type == MessageType.audio;
  bool get isVideo => type == MessageType.video;
  bool get isFile  => type == MessageType.file;
}
