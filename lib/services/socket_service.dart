import 'package:socket_io_client/socket_io_client.dart' as IO;
import '../config/app_config.dart';
import '../models/message.dart';

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  IO.Socket? _socket;
  bool _authenticated = false;
  bool get isAuthenticated => _authenticated;

  // ─── Callbacks ───────────────────────────────────────────────────────────

  void Function(Message message)? onMessageReceived;

  /// Appelé quand le statut de messages est mis à jour.
  /// [conversationId] : la conversation concernée.
  /// [status]         : le nouveau statut (2=distribué, 3=lu).
  /// [readBy]         : l'alanyaID de celui qui a lu (ou distribué).
  void Function(int conversationId, int status, int readBy)? onMessageStatusUpdated;

  void Function(int userId)? onTypingStarted;
  void Function(int userId)? onTypingStopped;

  /// [userId] : l'alanyaID de l'utilisateur, [isOnline] : son statut.
  void Function(int userId, bool isOnline)? onPresenceUpdated;

  void Function(String error)? onAuthError;

  // ─── Connexion ───────────────────────────────────────────────────────────

  void connect() {
    if (_socket != null && _socket!.connected) return;

    _socket = IO.io(
      AppConfig.serverUrl,
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    _socket!.onConnect((_) {
      print('[Socket] Connecté → auth:login');
      _socket!.emit('auth:login', {'token': AppConfig.token});
    });

    _socket!.onDisconnect((_) {
      print('[Socket] Déconnecté');
      _authenticated = false;
    });

    _socket!.onConnectError((err) => print('[Socket] Erreur connexion : $err'));

    // ── Auth ────────────────────────────────────────────────────────────
    _socket!.on('auth:verified', (data) {
      print('[Socket] Auth OK, alanyaID=${data['alanyaID']}');
      _authenticated = true;
      AppConfig.currentUserId = data['alanyaID'] ?? 0;
    });

    _socket!.on('auth:error', (data) {
      _authenticated = false;
      onAuthError?.call(data['message'] ?? 'Erreur inconnue');
    });

    // ── Messages ────────────────────────────────────────────────────────
    _socket!.on('message:received', (data) {
      try {
        final msg = Message.fromJson(Map<String, dynamic>.from(data));
        onMessageReceived?.call(msg);
      } catch (e) {
        print('[Socket] Erreur parsing message:received : $e');
      }
    });

    // ── Statut des messages ──────────────────────────────────────────────
    // Émis par le backend quand quelqu'un ouvre la conversation (status=3)
    // ou se connecte (status=2).
    // readBy = l'alanyaID de celui qui a effectué l'action.
    _socket!.on('message:status_updated', (data) {
      try {
        final convId = int.tryParse(data['conversationID'].toString()) ?? 0;
        final status = data['status'] as int? ?? 1;
        // readBy peut être int ou String selon le backend
        final readBy = int.tryParse(data['readBy'].toString()) ?? 0;
        onMessageStatusUpdated?.call(convId, status, readBy);
      } catch (e) {
        print('[Socket] Erreur parsing message:status_updated : $e');
      }
    });

    // ── Typing ──────────────────────────────────────────────────────────
    _socket!.on('typing:started', (data) => onTypingStarted?.call(data['userID'] ?? 0));
    _socket!.on('typing:stopped', (data) => onTypingStopped?.call(data['userID'] ?? 0));

    // ── Présence ────────────────────────────────────────────────────────
    _socket!.on('presence:updated', (data) {
      try {
        final userId = data['userID'] ?? 0;
        final isOnline = data['online'] ?? false;
        onPresenceUpdated?.call(userId, isOnline);
      } catch (e) {
        print('[Socket] Erreur parsing presence:updated : $e');
      }
    });

    _socket!.on('error', (data) => print('[Socket] Erreur serveur : $data'));

    _socket!.connect();
  }

  void disconnect() {
    _socket?.disconnect();
    _authenticated = false;
  }

  void joinConversation(int conversationId) {
    _socket?.emit('join_conversation', {'conversationID': conversationId});
  }

  void sendMessage({
    required int conversationId,
    required String content,
    int type = 0,
    String? mediaUrl,
    String? mediaName,
    int? mediaDuration,
  }) {
    if (!_authenticated) {
      print('[Socket] Non authentifié');
      return;
    }
    _socket?.emit('message:send', {
      'conversationID': conversationId,
      'content': content,
      'type': type,
      if (mediaUrl != null) 'mediaUrl': mediaUrl,
      if (mediaName != null) 'mediaName': mediaName,
      if (mediaDuration != null) 'mediaDuration': mediaDuration,
    });
  }

  void startTyping({required int conversationId, required int userId}) {
    _socket?.emit('typing:start', {'conversationID': conversationId, 'userID': userId});
  }

  void stopTyping({required int conversationId, required int userId}) {
    _socket?.emit('typing:stop', {'conversationID': conversationId, 'userID': userId});
  }
}
