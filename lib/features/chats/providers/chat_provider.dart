import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_model.dart';

const _kChatsKey = 'talky_chats';

List<Chat> _mockChats() {
  final now = DateTime.now();
  return List.generate(10, (i) {
    return Chat(
      userName: 'User ${i + 1}',
      isOnline: i % 3 == 0,
      messages: [
        Message(
          text: i % 2 == 0
              ? 'Hey, are we still meeting today?'
              : 'See you tomorrow!',
          isMe: false,
          time: now.subtract(Duration(minutes: i * 15)),
          isRead: false,
        ),
      ],
    );
  });
}

class ChatListNotifier extends Notifier<List<Chat>> {
  @override
  List<Chat> build() {
    _loadChats();
    return _mockChats();
  }

  Future<void> _loadChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kChatsKey);
      if (raw != null) {
        final List<dynamic> decoded = jsonDecode(raw);
        state = decoded
            .map((e) => Chat.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      // En cas d'erreur on garde les données mockées
      state = _mockChats();
    }
  }

  Future<void> _saveChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(state.map((c) => c.toJson()).toList());
      await prefs.setString(_kChatsKey, encoded);
    } catch (e) {
      // Silencieux — on ne bloque pas l'UI si la sauvegarde échoue
    }
  }

  void sendMessage(String chatId, String text) {
    state = state.map((chat) {
      if (chat.id != chatId) return chat;
      final newMessage = Message(
        text: text,
        isMe: true,
        time: DateTime.now(),
        isRead: true,
      );
      return chat.copyWith(messages: [...chat.messages, newMessage]);
    }).toList();
    _saveChats();
  }

  void markAsRead(String chatId) {
    state = state.map((chat) {
      if (chat.id != chatId) return chat;
      final updatedMessages = chat.messages
          .map((m) => m.isMe ? m : m.copyWith(isRead: true))
          .toList();
      return chat.copyWith(messages: updatedMessages);
    }).toList();
    _saveChats();
  }

  void updateAvatar(String chatId, String path) {
    state = state.map((chat) {
      if (chat.id != chatId) return chat;
      return chat.copyWith(avatarPath: path);
    }).toList();
    _saveChats();
  }

  void addChat(String userName, {bool isGroup = false, bool isBroadcast = false}) {
    final newChat = Chat(
      userName: userName,
      isGroup: isGroup,
      isBroadcast: isBroadcast,
    );
    state = [newChat, ...state];
    _saveChats();
  }

  void deleteChat(String chatId) {
    state = state.where((c) => c.id != chatId).toList();
    _saveChats();
  }

  Chat? getChatById(String chatId) {
    try {
      return state.firstWhere((c) => c.id == chatId);
    } catch (_) {
      return null;
    }
  }
}

final chatListProvider = NotifierProvider<ChatListNotifier, List<Chat>>(() {
  return ChatListNotifier();
});

final searchQueryProvider = StateProvider<String>((ref) => '');

// Typing indicator par chatId
final typingProvider = StateProvider<Map<String, bool>>((ref) => {});

final filteredChatsProvider = Provider<List<Chat>>((ref) {
  final chats = ref.watch(chatListProvider);
  final query = ref.watch(searchQueryProvider).toLowerCase().trim();
  if (query.isEmpty) return chats;
  return chats.where((chat) {
    final matchesName = chat.userName.toLowerCase().contains(query);
    final matchesMessage =
        chat.messages.any((m) => m.text.toLowerCase().contains(query));
    return matchesName || matchesMessage;
  }).toList();
});