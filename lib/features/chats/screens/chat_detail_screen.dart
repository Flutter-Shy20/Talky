import 'dart:io';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../models/chat_model.dart';
import '../providers/chat_provider.dart';
import '../providers/real_chat_provider.dart';
import '../widgets/chat_avatar.dart';
import '../../calls/ongoing_call_screen.dart';
import 'package:flutter/services.dart';

class ChatDetailScreen extends ConsumerStatefulWidget {
  final Chat chat;
  const ChatDetailScreen({super.key, required this.chat});

  @override
  ConsumerState<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends ConsumerState<ChatDetailScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _showEmojiPicker = false;
  bool _isTyping = false;
  List<Message> _realMessages = []; // ← nouveau : messages vrais
  bool _loadingMessages = true;     // ← nouveau : état de chargement

  @override
  void initState() {
    super.initState();
    _loadMessages();          // ← nouveau
    _listenToSocketMessages(); // ← nouveau
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    _messageController.addListener(_onTypingChanged);
  }

  @override
  void dispose() {
    // Arrête d'écouter le socket quand on quitte le chat
    final api = ref.read(apiClientProvider);
    api.offSocketEvent('message:receive');
    _messageController.removeListener(_onTypingChanged);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── NOUVEAU : Charge les vrais messages depuis le backend ──
  Future<void> _loadMessages() async {
    setState(() => _loadingMessages = true);
    try {
      final api = ref.read(apiClientProvider);
      // ← Utilise le cache du provider
      final messages = await ref
          .read(realChatProvider.notifier)
          .fetchMessages(widget.chat.id, api);
      if (mounted) {
        setState(() {
          _realMessages = List.from(messages); // ← copie depuis le cache
          _loadingMessages = false;
        });
        Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
      }
    } catch (e) {
      if (mounted) setState(() => _loadingMessages = false);
    }
  }

  // ── NOUVEAU : Écoute les messages entrants via Socket.IO ──
  void _listenToSocketMessages() {
    final api = ref.read(apiClientProvider);
    api.onSocketEvent('message:receive', (data) {
      if (!mounted) return;
      final conversId = data['conversationID']?.toString() ?? 
                        data['conversID']?.toString() ?? '';
      if (conversId == widget.chat.id) {
        // Le provider global a déjà mis à jour le cache
        // On recharge juste l'affichage local
        final cached = ref
        .read(realChatProvider.notifier)
        .getCachedMessages(widget.chat.id);
        setState(() => _realMessages = List.from(cached));
        _scrollToBottom();
      }
    });
  }

  /*
  void _listenToSocketMessages() {
    final api = ref.read(apiClientProvider);
    api.onSocketEvent('message:receive', (data) {
      if (!mounted) return;
      // Vérifie que le message appartient à cette conversation
      if (data['conversationID']?.toString() == widget.chat.id) {
        final msg = Message(
          id: data['messageID']?.toString() ?? '',
          text: data['content'] ?? '',
          isMe: false,
          time: DateTime.tryParse(data['created_at'] ?? '') ?? DateTime.now(),
          isRead: false,
        );
        setState(() => _realMessages.add(msg));
        _scrollToBottom();
      }
    });
  }
  */


  void _onTypingChanged() {
    final typing = _messageController.text.isNotEmpty;
    if (typing != _isTyping) {
      setState(() => _isTyping = typing);
      final current = ref.read(typingProvider);
      ref.read(typingProvider.notifier).state = {
        ...current,
        widget.chat.id: typing,
      };
      // ← nouveau : envoie le typing au backend via Socket
      final api = ref.read(apiClientProvider);
      api.sendSocketEvent('typing', {
        'conversationID': widget.chat.id,
        'isTyping': typing,
      });
    }
  }
  /*
  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }
  */

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }


  String _formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  // ── MODIFIÉ : Envoi via backend ──
  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    // Affichage optimiste immédiat
    final optimisticMsg = Message(
      text: text,
      isMe: true,
      time: DateTime.now(),
      isRead: true,
    );

    setState(() {
      _realMessages.add(optimisticMsg);
      //debugPrint("Messages locaux: ${_realMessages.length}");
      //debugPrint("Dernier message: ${optimisticMsg.text}");
      _showEmojiPicker = false;
    });
    _messageController.clear();
    //_scrollToBottom();
    Future.delayed(
      const Duration(milliseconds: 100),
      _scrollToBottom,
    );

    // Envoi au backend
   _sendToBackend(optimisticMsg, text);
  }

  Future<void> _sendToBackend(Message optimisticMsg, String text) async {
     try {
      final api = ref.read(apiClientProvider);

      debugPrint('[Chat] Envoi message: $text');
      debugPrint('[Chat] conversationId: ${widget.chat.id}');

      await ref.read(realChatProvider.notifier).sendMessage(
        conversationId: widget.chat.id,
        text: text,
        api: api,
      );

      // ← Recharge depuis le cache pour être sûr d'être à jour
      final updated = await ref
        .read(realChatProvider.notifier)
        .fetchMessages(widget.chat.id, api);

      debugPrint('[Chat] Message apres envoi: ${updated.length}');
      for (final m in updated){
        debugPrint('[Chat] -> isMe=${m.isMe} | text=${m.text}');
      }

      if (mounted) setState(() => _realMessages = List.from(updated));
    } catch (e) {
      debugPrint('[Chat] Erreur _sendToBackend: $e');
      // En cas d'erreur, retire le message optimiste
      if (mounted) {
        setState(() => _realMessages.remove(optimisticMsg));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Échec envoi du message')),
        );
      }
    }
  } 

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (picked != null) {
      ref.read(chatListProvider.notifier).updateAvatar(
            widget.chat.id,
            picked.path,
          );
    }
  }

  Future<void> _pickAttachment() async {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Share',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildAttachOption(
                    Icons.image, 'Gallery', Colors.purple, () async {
                  Navigator.pop(context);
                  final picker = ImagePicker();
                  final picked = await picker.pickImage(
                      source: ImageSource.gallery);
                  if (picked != null && mounted) {
                    await ref.read(realChatProvider.notifier).sendMessage(
                          conversationId: widget.chat.id,
                          text: '📷 Image: ${picked.name}',
                          api: ref.read(apiClientProvider),
                        );
                    _scrollToBottom();
                  }
                }),
                _buildAttachOption(
                    Icons.camera_alt, 'Camera', Colors.red, () async {
                  Navigator.pop(context);
                  final picker = ImagePicker();
                  final picked =
                      await picker.pickImage(source: ImageSource.camera);
                  if (picked != null && mounted) {
                    await ref.read(realChatProvider.notifier).sendMessage(
                          conversationId: widget.chat.id,
                          text: '📷 Photo: ${picked.name}',
                          api: ref.read(apiClientProvider),
                        );
                    _scrollToBottom();
                  }
                }),
                _buildAttachOption(
                    Icons.location_on, 'Location', Colors.green, () async {
                  Navigator.pop(context);
                  await ref.read(realChatProvider.notifier).sendMessage(
                        conversationId: widget.chat.id,
                        text: '📍 Location shared',
                        api: ref.read(apiClientProvider),
                      );
                  _scrollToBottom();
                }),
                _buildAttachOption(
                    Icons.person, 'Contact', Colors.blue, () async {
                  Navigator.pop(context);
                  await ref.read(realChatProvider.notifier).sendMessage(
                        conversationId: widget.chat.id,
                        text: '👤 Contact shared',
                        api: ref.read(apiClientProvider),
                      );
                  _scrollToBottom();
                }),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachOption(
      IconData icon, String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: color.withOpacity(0.1),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // On garde le chat local pour les infos (nom, avatar, statut)
    final chats = ref.watch(chatListProvider);
    final chatInfo = chats.firstWhere(
      (c) => c.id == widget.chat.id,
      orElse: () => widget.chat,
    );
    final typingMap = ref.watch(typingProvider);
    final someoneTyping = typingMap[chatInfo.id] ?? false;

    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
        title: GestureDetector(
          onTap: _pickAvatar,
          child: Row(
            children: [
              Stack(
                children: [
                  ChatAvatar(
                    userName: chatInfo.userName,
                    avatarPath: chatInfo.avatarPath,
                    radius: 18,
                    isGroup: chatInfo.isGroup,
                    isBroadcast: chatInfo.isBroadcast,
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Colors.indigo,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: const Icon(Icons.edit, size: 7, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chatInfo.userName,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  someoneTyping
                      ? const Text(
                          'typing...',
                          style: TextStyle(
                            color: Colors.indigo,
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                          ),
                        )
                      : Text(
                          chatInfo.isOnline ? 'Online' : 'Offline',
                          style: TextStyle(
                            color: chatInfo.isOnline ? Colors.green : Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam, color: Colors.indigo),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const OngoingCallScreen(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.call, color: Colors.indigo),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const OngoingCallScreen(),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loadingMessages
                ? const Center(child: CircularProgressIndicator())
                : _realMessages.isEmpty
                    ? Center(
                        child: Text(
                          'Aucun message. Dis bonjour ! 👋',
                          style: TextStyle(color: Colors.grey.shade400),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: _realMessages.length,
                        itemBuilder: (context, index) {
                          final message = _realMessages[index];
                          return Align(
                            alignment: message.isMe
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: message.isMe
                                    ? Colors.indigo
                                    : Colors.white,
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(20),
                                  topRight: const Radius.circular(20),
                                  bottomLeft: message.isMe
                                      ? const Radius.circular(20)
                                      : Radius.zero,
                                  bottomRight: message.isMe
                                      ? Radius.zero
                                      : const Radius.circular(20),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 5,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: message.isMe
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    message.text,
                                    style: TextStyle(
                                      color: message.isMe
                                          ? Colors.white
                                          : Colors.black87,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _formatTime(message.time),
                                    style: TextStyle(
                                      color: message.isMe
                                          ? Colors.white70
                                          : Colors.black45,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
          // Zone de saisie
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      _showEmojiPicker
                          ? Icons.keyboard
                          : Icons.emoji_emotions_outlined,
                      color: Colors.grey,
                    ),
                    onPressed: () {
                      setState(() => _showEmojiPicker = !_showEmojiPicker);
                      if (_showEmojiPicker) {
                        FocusScope.of(context).unfocus();
                      }
                    },
                  ),
                  Expanded(
                    child: RawKeyboardListener(
                      focusNode: FocusNode(),
                      onKey: (event) => {
                        if(event.isKeyPressed(LogicalKeyboardKey.enter) && !event.isShiftPressed){
                          _sendMessage()
                        }
                      }, 
                      child: TextField(
                        controller: _messageController,
                        onTap: () {
                          if (_showEmojiPicker) {
                            setState(() => _showEmojiPicker = false);
                          }
                        },
                        maxLines: null,
                        textInputAction: TextInputAction.send, // ← force le bouton "Envoyer"
                        onSubmitted: (_) => _sendMessage(),    // ← déjà là mais renforcé
                        onEditingComplete: _sendMessage,       // ← nouveau : backup sur Enter
                        decoration: InputDecoration(
                          hintText: 'Type a message...',
                          hintStyle: TextStyle(color: Colors.grey.shade400),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: Colors.grey.shade100,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.attach_file, color: Colors.grey),
                            onPressed: _pickAttachment,
                          ),
                        ),
                        //onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: const BoxDecoration(
                      color: Colors.indigo,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.white, size: 20),
                      onPressed: _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Emoji Picker
          if (_showEmojiPicker)
            SizedBox(
              height: 280,
              child: EmojiPicker(
                onEmojiSelected: (category, emoji) {
                  _messageController.text += emoji.emoji;
                  _messageController.selection = TextSelection.fromPosition(
                    TextPosition(offset: _messageController.text.length),
                  );
                },
                config: const Config(
                  height: 280,
                  emojiViewConfig: EmojiViewConfig(columns: 8),
                  categoryViewConfig: CategoryViewConfig(
                    initCategory: Category.RECENT,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}