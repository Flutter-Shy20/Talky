/*
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart' as legacy;
import 'package:flutter/material.dart';
import '../models/chat_model.dart';
import 'chat_provider.dart';
import '../../../talky_api_client.dart';

// ── Provider qui donne accès au TalkyApiClient depuis Riverpod ──
final apiClientProvider = Provider<TalkyApiClient>((ref) {
  throw UnimplementedError('Wrap avec ApiClientScope');
});

// ── Provider principal des conversations réelles ──
final realChatProvider = AsyncNotifierProvider<RealChatNotifier, List<Chat>>(
  RealChatNotifier.new,
);

class RealChatNotifier extends AsyncNotifier<List<Chat>> {
  @override
  Future<List<Chat>> build() async {
    final api = ref.read(apiClientProvider);
    return _fetchConversations(api);
  }

  Future<List<Chat>> _fetchConversations(TalkyApiClient api) async {
    try {
      final raw = await api.getConversations();
      debugPrint('[RealChat] ======= CONVERSATIONS =======');
      debugPrint('[RealChat] Nombre: ${raw.length}');
      for(final c in raw){
        debugPrint('[RealChat] Conversation: $c');
      }
      return raw.map((c) => _mapConversation(c as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('[RealChat] Erreur: $e');
      return [];
    }
  }

  // Convertit un objet JSON du backend en Chat local
  Chat _mapConversation(Map<String, dynamic> c, int myId) {
    final lastMsgRaw = c['lastMessage'];
    final List<Message> messages = [];

    if (lastMsgRaw != null) {
      messages.add(Message(
        id: lastMsgRaw['messageID']?.toString() ?? '',
        text: lastMsgRaw['content'] ?? '',
        isMe: false, // sera affiné avec l'ID utilisateur connecté
        time: DateTime.tryParse(lastMsgRaw['created_at'] ?? '') ?? DateTime.now(),
        isRead: (lastMsgRaw['isRead'] ?? 0) == 1,
      ));
    }

    return Chat(
      id: c['conversationID']?.toString() ?? '',
      userName: c['GroupName'] ?? c['otherUserName'] ?? 'Inconnu',
      isOnline: (c['is_online'] ?? 0) == 1,
      messages: messages,
      avatarPath: c['avatar_url'] ?? c['groupPhoto'],
      isGroup: (c['isGroup'] ?? 0) == 1,
    );
  }

  // Charge les messages d'une conversation
  Future<List<Message>> fetchMessages(String conversationId, TalkyApiClient api) async {
    try {
      debugPrint('[RealChat] Chargement messages pour conversationID: $conversationId');
      final raw = await api.getMessages(int.parse(conversationId));
      debugPrint('[RealChat] Messages recus: ${raw.length}');
      for(final m in raw){
        debugPrint('[RealChat] Message: $m');
      }
      return raw.map((m) => _mapMessage(m)).toList();
    } catch (e) {
      debugPrint('[RealChat] Erreur: $e');
      return [];
    }
  }

  Message _mapMessage(Map<String, dynamic> m) {
    return Message(
      id: m['messageID']?.toString() ?? '',
      text: m['content'] ?? '',
      isMe: m['isMe'] == true || m['isMe'] == 1,
      time: DateTime.tryParse(m['created_at'] ?? '') ?? DateTime.now(),
      isRead: (m['isRead'] ?? 0) == 1,
    );
  }

  // Envoie un message via REST + Socket.IO
  Future<void> sendMessage({
    required String conversationId,
    required String text,
    required TalkyApiClient api,
  }) async {
    try {
      // 1. Envoie via REST
      await api.sendMessage(
        conversID: int.parse(conversationId),
        content: text,
      );

      // 2. Rafraîchit la liste
      state = AsyncData(await _fetchConversations(api));
    } catch (e) {
      debugPrint('[RealChatProvider] Erreur sendMessage: $e');
    }
  }

  // Rafraîchit toutes les conversations
  Future<void> refresh(TalkyApiClient api) async {
    state = const AsyncLoading();
    state = AsyncData(await _fetchConversations(api));
  }
}

// ── Provider filtré (identique à l'existant) ──
final realFilteredChatsProvider = Provider<AsyncValue<List<Chat>>>((ref) {
  final chatsAsync = ref.watch(realChatProvider);
  final query = ref.watch(searchQueryProvider).toLowerCase().trim();

  return chatsAsync.whenData((chats) {
    if (query.isEmpty) return chats;
    return chats.where((chat) {
      final matchesName = chat.userName.toLowerCase().contains(query);
      final matchesMessage =
          chat.messages.any((m) => m.text.toLowerCase().contains(query));
      return matchesName || matchesMessage;
    }).toList();
  });
});
*/
import 'package:uuid/uuid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import '../models/chat_model.dart';
import 'chat_provider.dart';
import '../../../talky_api_client.dart';

// ── Provider qui donne accès au TalkyApiClient depuis Riverpod ──
final apiClientProvider = Provider<TalkyApiClient>((ref) {
  throw UnimplementedError('Wrap avec ApiClientScope');
});

// ── Provider principal des conversations réelles ──
final realChatProvider = AsyncNotifierProvider<RealChatNotifier, List<Chat>>(
  RealChatNotifier.new,
);

class RealChatNotifier extends AsyncNotifier<List<Chat>> {

  int _myId = 0; // ← stocke ton propre ID

  final Map<String, List<Message>> _messagesCache = {};

  @override
  Future<List<Chat>> build() async {
    final api = ref.read(apiClientProvider);
    final chats = await _fetchConversations(api);
    startListening(api); //Demarre l'ecoute globale
    return chats;
  }


  // ← Démarre l'écoute globale des messages entrants
  void startListening(TalkyApiClient api) {
    api.onSocketEvent('message:receive', (data) async {
      debugPrint('[RealChat] 📨 Message reçu: $data');
      final conversId = data['conversationID']?.toString() ?? 
                        data['conversID']?.toString() ?? '';
      if (conversId.isEmpty) return;

      final newMsg = Message(
        id: data['messageID']?.toString() ?? '',
        text: data['content']?.toString() ?? '',
        isMe: false,
        time: DateTime.tryParse(data['created_at']?.toString() ?? '') ?? DateTime.now(),
        isRead: false,
      );

      // Met à jour le cache des messages
      final existing = _messagesCache[conversId] ?? [];
      _messagesCache[conversId] = [...existing, newMsg];

      // Rafraîchit la liste des conversations
      final updated = await _fetchConversations(api);
      state = AsyncData(updated);
    });
  }

  Future<List<Chat>> _fetchConversations(TalkyApiClient api) async {
    try {
      // ← Récupère ton propre ID pour identifier l'autre participant
      final me = await api.getMe();
      _myId = me['alanyaID'] as int? ?? 0;
      debugPrint('[RealChat] Mon ID: $_myId');

      final raw = await api.getConversations();
      debugPrint('[RealChat] ======= CONVERSATIONS =======');
      debugPrint('[RealChat] Nombre: ${raw.length}');

      return raw
          .map((c) => _mapConversation(c as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[RealChat] Erreur: $e');
      return [];
    }
  }

  // Convertit un objet JSON du backend en Chat local
  Chat _mapConversation(Map<String, dynamic> c) {
    // ← Le bon champ est "conversID" pas "conversationID"
    final conversId = c['conversID']?.toString() ?? '';

    // ← Le nom est dans participants, on exclut notre propre compte
    final participants = c['participants'] as List<dynamic>? ?? [];
    final other = participants.firstWhere(
      (p) => (p['alanyaID'] as int?) != _myId,
      orElse: () => participants.isNotEmpty ? participants.first : <String, dynamic>{},
    );

    final userName = other['nom'] ?? other['pseudo'] ?? 'Inconnu';
    final isOnline = (other['is_online'] ?? 0) == 1;
    final avatarUrl = other['avatar_url'];

    // ← lastMessage peut être null
    
    final List<Message> messages = [];
    /*
    final lastMsgRaw = c['lastMessage'];
    if (lastMsgRaw != null) {
      messages.add(Message(
        id: lastMsgRaw['messageID']?.toString() ?? '',
        text: lastMsgRaw['content'] ?? '',
        isMe: (lastMsgRaw['senderID'] as int?) == _myId,
        time: DateTime.tryParse(lastMsgRaw['created_at'] ?? '') ?? DateTime.now(),
        isRead: (lastMsgRaw['isRead'] ?? 0) == 1,
      ));
    }
    

    final lastMsgRaw = c['lastMessage'];
    if (lastMsgRaw != null && lastMsgRaw is Map<String, dynamic>) {
      messages.add(Message(
        // ← toString() sur tous les champs susceptibles d'être String ou int
        id: lastMsgRaw['messageID']?.toString() ?? '',
        text: lastMsgRaw['content']?.toString() ?? '',
        isMe: lastMsgRaw['senderID']?.toString() == _myId.toString(),
        time: DateTime.tryParse(lastMsgRaw['created_at']?.toString() ?? '') ?? DateTime.now(),
        isRead: lastMsgRaw['isRead'] == 1 || lastMsgRaw['isRead'] == true,
      ));
    }
    */

    final lastMsgRaw = c['lastMessage'];
    if (lastMsgRaw != null && lastMsgRaw is Map) {
      messages.add(Message(
        id: lastMsgRaw['messageID']?.toString() ?? '',  // ← toString() partout
        text: lastMsgRaw['content']?.toString() ?? '',
        isMe: lastMsgRaw['senderID']?.toString() == _myId.toString(),
        time: DateTime.tryParse(lastMsgRaw['created_at']?.toString() ?? '') ?? DateTime.now(),
        isRead: lastMsgRaw['isRead'] == 1 || lastMsgRaw['isRead'] == true,
      ));
    }



    debugPrint('[RealChat] Conversation $conversId → $userName (online: $isOnline)');

    return Chat(
      id: conversId,
      userName: userName,
      isOnline: isOnline,
      messages: messages,
      avatarPath: avatarUrl,
      isGroup: (c['isGroup'] ?? 0) == 1,
    );
  }

  // Charge les messages d'une conversation
  Future<List<Message>> fetchMessages(
      String conversationId, TalkyApiClient api) async {
    try {
      // ← Guard : évite le FormatException si l'ID est vide
      if (conversationId.isEmpty) return [];
      /*
      if (_messagesCache.containsKey(conversationId)){
        return _messagesCache[conversationId]!;
      }
      */

      debugPrint('[RealChat] Chargement messages pour conversationID: $conversationId');
      final raw = await api.getMessages(int.parse(conversationId));
      debugPrint('[RealChat] Messages reçus: ${raw.length}');
      final messages = raw
        .map((m) => _mapMessage(m as Map<String, dynamic>))
        .toList();

      _messagesCache[conversationId] = messages;

      return messages;

    } catch (e) {
      debugPrint('[RealChat] Erreur messages: $e');
      return [];
    }
  }

  void addMessageToCache(String conversationId, Message message) {
    final messages = _messagesCache[conversationId] ?? [];
    _messagesCache[conversationId] = [...messages, message]; 
  }

  List<Message> getCachedMessages(String conversationId) {
    return _messagesCache[conversationId] ?? [];
  }

  /*
  Message _mapMessage(Map<String, dynamic> m) {
    return Message(
      id: m['messageID']?.toString() ?? m['id']?.toString() ?? '',
      text: m['content'] ?? '',
      isMe: m['isMe'] == true || m['isMe'] == 1,
      time: DateTime.tryParse(m['created_at'] ?? '') ?? DateTime.now(),
      isRead: (m['isRead'] ?? 0) == 1,
    );
  }
  */

  Message _mapMessage(Map<String, dynamic> m) {
    //final senderId = m['senderID'] as int? ?? 0;
    /*
    return Message(
      id: m['messageID']?.toString() ??
          m['id']?.toString() ??
          const Uuid().v4(),

      text: m['content'] ?? '',

      isMe: senderId == _myId,

      time: DateTime.tryParse(
            m['created_at'] ?? '',
          ) ??
          DateTime.now(),

      isRead: (m['isRead'] ?? 0) == 1,
    );
    */
   
    return Message(
      // ← toString() au lieu de cast direct
      id: m['messageID']?.toString() ?? m['id']?.toString() ?? '',
      text: m['content'] ?? '',
      isMe: m['isMe'] == true || m['isMe'] == 1,
      time: DateTime.tryParse(m['created_at'] ?? '') ?? DateTime.now(),
      isRead: (m['isRead'] ?? 0) == 1,
    );

  }

  // Envoie un message via REST
  Future<void> sendMessage({
    required String conversationId,
    required String text,
    required TalkyApiClient api,
  }) async {
    try {
      if (conversationId.isEmpty) return;

      await api.sendMessage(
        conversID: int.parse(conversationId),
        content: text,
      );

      // ← Ajoute au cache local immédiatement
      addMessageToCache(
        conversationId, 
        Message(
          text: text, 
          isMe: true, 
          time: DateTime.now(),
          isRead: true,
        )
      );

      // Rafraîchit la liste après envoi
      state = AsyncData(await _fetchConversations(api));
    } catch (e) {
      debugPrint('[RealChatProvider] Erreur sendMessage: $e');
    }
  }

  // Rafraîchit toutes les conversations
  Future<void> refresh(TalkyApiClient api) async {
    state = const AsyncLoading();
    state = AsyncData(await _fetchConversations(api));
  }
}

// ── Provider filtré ──
final realFilteredChatsProvider = Provider<AsyncValue<List<Chat>>>((ref) {
  final chatsAsync = ref.watch(realChatProvider);
  final query = ref.watch(searchQueryProvider).toLowerCase().trim();

  return chatsAsync.whenData((chats) {
    if (query.isEmpty) return chats;
    return chats.where((chat) {
      final matchesName = chat.userName.toLowerCase().contains(query);
      final matchesMessage =
          chat.messages.any((m) => m.text.toLowerCase().contains(query));
      return matchesName || matchesMessage;
    }).toList();
  });
});