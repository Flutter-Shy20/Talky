import 'package:flutter/material.dart';
import '../../config/app_config.dart';
import '../../services/api_service.dart';
import '../../services/socket_service.dart';
import '../../models/conversation.dart';
import 'chat_detail_screen.dart';
import 'new_chat_screen.dart';

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  final _api = ApiService();
  final _socket = SocketService();

  List<Conversation> _conversations = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _socket.connect();
    _loadConversations();
  }

  Future<void> _loadConversations() async {
    if (!AppConfig.isTokenSet) {
      setState(() {
        _error = 'Token non configuré.\nOuvre lib/config/app_config.dart et remplis AppConfig.token.';
        _isLoading = false;
      });
      return;
    }
    try {
      setState(() { _isLoading = true; _error = null; });
      final convs = await _api.getConversations();
      setState(() { _conversations = convs; _isLoading = false; });
    } catch (e) {
      setState(() { _error = 'Erreur de chargement.\n$e'; _isLoading = false; });
    }
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}min';
    if (diff.inHours < 24) return '${dt.hour}h${dt.minute.toString().padLeft(2, '0')}';
    return '${dt.day}/${dt.month}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text('Chats',
            style: TextStyle(color: Colors.black, fontSize: 28, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.black),
            onPressed: _loadConversations,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Rechercher...',
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                filled: true,
                fillColor: Colors.grey.shade100,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.push(context,
              MaterialPageRoute(builder: (_) => const NewChatScreen()));
          _loadConversations();
        },
        backgroundColor: Colors.indigo,
        child: const Icon(Icons.chat, color: Colors.white),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator(color: Colors.indigo));

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey, fontSize: 14)),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loadConversations,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo),
                child: const Text('Réessayer', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      );
    }

    if (_conversations.isEmpty) {
      return const Center(
        child: Text('Aucune conversation.\nAppuie sur + pour en démarrer une.',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadConversations,
      color: Colors.indigo,
      child: ListView.builder(
        itemCount: _conversations.length,
        itemBuilder: (context, index) {
          final conv = _conversations[index];
          // Nom = interlocuteur pour 1-to-1, GroupName pour groupe
          final name = conv.displayName(AppConfig.currentUserId);
          final avatar = conv.displayAvatar(AppConfig.currentUserId);

          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            leading: CircleAvatar(
              radius: 28,
              backgroundColor: Colors.indigo.shade100,
              child: avatar != null
                  ? ClipOval(
                      child: Image.network(avatar, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _initials(name)))
                  : _initials(name),
            ),
            title: Text(name,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            subtitle: Text(
              conv.lastMessage ?? 'Démarrer la conversation',
              style: TextStyle(
                color: conv.unreadCount > 0 ? Colors.black87 : Colors.grey.shade600,
                fontWeight: conv.unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_formatTime(conv.lastMessageAt),
                    style: TextStyle(
                        fontSize: 12,
                        color: conv.unreadCount > 0 ? Colors.indigo : Colors.grey)),
                const SizedBox(height: 4),
                if (conv.unreadCount > 0)
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(
                        color: Colors.indigo, shape: BoxShape.circle),
                    child: Text('${conv.unreadCount}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatDetailScreen(
                    conversationId: conv.id,
                    conversationName: name,
                    otherParticipantId: conv.otherParticipantId(AppConfig.currentUserId),
                    initialOnline: conv.isOtherOnline(AppConfig.currentUserId),
                  ),
                ),
              );
              // On recharge la liste dès qu'on revient du chat :
              // le backend a marqué les messages comme lus → unreadCount = 0
              _loadConversations();
            },
          );
        },
      ),
    );
  }

  Widget _initials(String name) {
    return Text(
      name.isNotEmpty ? name[0].toUpperCase() : '?',
      style: const TextStyle(
          color: Colors.indigo, fontWeight: FontWeight.bold, fontSize: 18),
    );
  }
}
