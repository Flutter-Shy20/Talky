import 'package:uuid/uuid.dart';

class Message {
  final String id;
  final String text;
  final bool isMe;
  final DateTime time;
  final bool isRead;

  Message({
    String? id,
    required this.text,
    required this.isMe,
    required this.time,
    this.isRead = false,
  }) : id = id ?? const Uuid().v4();

  Message copyWith({bool? isRead}) {
    return Message(
      id: id,
      text: text,
      isMe: isMe,
      time: time,
      isRead: isRead ?? this.isRead,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'isMe': isMe,
        'time': time.toIso8601String(),
        'isRead': isRead,
      };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'],
        text: json['text'],
        isMe: json['isMe'],
        time: DateTime.parse(json['time']),
        isRead: json['isRead'] ?? false,
      );
}

class Chat {
  final String id;
  final String userName;
  final bool isOnline;
  final List<Message> messages;
  final String? avatarPath;
  final bool isGroup;
  final bool isBroadcast;

  Chat({
    String? id,
    required this.userName,
    this.isOnline = false,
    List<Message>? messages,
    this.avatarPath,
    this.isGroup = false,
    this.isBroadcast = false,
  })  : id = id ?? const Uuid().v4(),
        messages = messages ?? [];

  Message? get lastMessage => messages.isEmpty ? null : messages.last;

  int get unreadCount =>
      messages.where((m) => !m.isMe && !m.isRead).length;

  Chat copyWith({
    List<Message>? messages,
    String? avatarPath,
  }) {
    return Chat(
      id: id,
      userName: userName,
      isOnline: isOnline,
      messages: messages ?? this.messages,
      avatarPath: avatarPath ?? this.avatarPath,
      isGroup: isGroup,
      isBroadcast: isBroadcast,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'userName': userName,
        'isOnline': isOnline,
        'avatarPath': avatarPath,
        'isGroup': isGroup,
        'isBroadcast': isBroadcast,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Chat.fromJson(Map<String, dynamic> json) => Chat(
        id: json['id'],
        userName: json['userName'],
        isOnline: json['isOnline'] ?? false,
        avatarPath: json['avatarPath'],
        isGroup: json['isGroup'] ?? false,
        isBroadcast: json['isBroadcast'] ?? false,
        messages: (json['messages'] as List<dynamic>)
            .map((m) => Message.fromJson(m as Map<String, dynamic>))
            .toList(),
      );
}