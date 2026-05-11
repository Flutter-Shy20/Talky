import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import '../models/conversation.dart';
import '../models/message.dart';

/// Service qui gère tous les appels HTTP vers le backend Alanya.
///
/// TOUTES les requêtes utilisent automatiquement :
///   - AppConfig.serverUrl comme base URL
///   - AppConfig.token comme Bearer token
class ApiService {
  // ─── Singleton ──────────────────────────────────────────────────────────
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  // ─── Utilitaires internes ────────────────────────────────────────────────

  Uri _uri(String path) => Uri.parse('${AppConfig.serverUrl}$path');

  /// Lève une exception lisible si le serveur renvoie une erreur.
  void _checkStatus(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = jsonDecode(response.body);
      final message = body['message'] ?? body['error'] ?? 'Erreur serveur';
      throw Exception('[${ response.statusCode}] $message');
    }
  }

  // ─── CONVERSATIONS ───────────────────────────────────────────────────────

  /// GET /api/conversations
  /// Renvoie la liste de toutes les conversations de l'utilisateur connecté.
  Future<List<Conversation>> getConversations() async {
    final response = await http.get(
      _uri('/api/conversations'),
      headers: AppConfig.authHeaders,
    );
    _checkStatus(response);

    final List<dynamic> data = jsonDecode(response.body);
    return data.map((json) => Conversation.fromJson(json)).toList();
  }

  /// POST /api/conversations
  /// Crée une nouvelle conversation avec un autre utilisateur.
  ///
  /// [participantId] : l'alanyaID de la personne avec qui tu veux discuter.
  Future<Conversation> createConversation(int participantId) async {
    final response = await http.post(
      _uri('/api/conversations'),
      headers: AppConfig.authHeaders,
      body: jsonEncode({'participantID': participantId}),
    );
    _checkStatus(response);
    return Conversation.fromJson(jsonDecode(response.body));
  }

  // ─── MESSAGES ───────────────────────────────────────────────────────────

  /// GET /api/conversations/:id/messages
  /// Récupère les 50 derniers messages d'une conversation.
  ///
  /// [conversationId] : l'ID de la conversation.
  /// [before] : (optionnel) ID de message pour paginer vers le passé.
  Future<List<Message>> getMessages(int conversationId, {int? before}) async {
    String path = '/api/conversations/$conversationId/messages';
    if (before != null) path += '?before=$before';

    final response = await http.get(
      _uri(path),
      headers: AppConfig.authHeaders,
    );
    _checkStatus(response);

    final List<dynamic> data = jsonDecode(response.body);
    // Le backend renvoie les messages du plus récent au plus ancien.
    // On inverse pour afficher dans l'ordre chronologique.
    final messages = data.map((json) => Message.fromJson(json)).toList();
    return messages.reversed.toList();
  }

  /// POST /api/conversations/:id/messages
  /// Envoie un message texte via HTTP (alternative au socket).
  Future<Message> sendMessageHttp(int conversationId, String content) async {
    final response = await http.post(
      _uri('/api/conversations/$conversationId/messages'),
      headers: AppConfig.authHeaders,
      body: jsonEncode({'content': content, 'type': 0}),
    );
    _checkStatus(response);
    return Message.fromJson(jsonDecode(response.body));
  }

  /// POST /api/conversations/:id/read
  /// Marque tous les messages d'une conversation comme lus.
  Future<void> markAsRead(int conversationId) async {
    final response = await http.post(
      _uri('/api/conversations/$conversationId/read'),
      headers: AppConfig.authHeaders,
    );
    _checkStatus(response);
  }
}
