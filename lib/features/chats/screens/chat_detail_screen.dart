import 'dart:io';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../models/chat_model.dart';
import '../providers/chat_provider.dart';
import '../widgets/chat_avatar.dart';
import '../../calls/ongoing_call_screen.dart';

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

  @override
  void initState() {
    super.initState();
    Future.microtask(() =>
      ref.read(chatListProvider.notifier).markAsRead(widget.chat.id)
      // Scroll automatique à l'ouverture
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    _messageController.addListener(_onTypingChanged);
  }

  @override
  void dispose() {
    _messageController.removeListener(_onTypingChanged);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onTypingChanged() {
    final typing = _messageController.text.isNotEmpty;
    if (typing != _isTyping) {
      setState(() => _isTyping = typing);
      // Met à jour le typing indicator dans le provider
      final current = ref.read(typingProvider);
      ref.read(typingProvider.notifier).state = {
        ...current,
        widget.chat.id: typing,
      };
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  String _formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    ref.read(chatListProvider.notifier).sendMessage(widget.chat.id, text);
    _messageController.clear();
    setState(() => _showEmojiPicker = false);
    Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
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
                    ref.read(chatListProvider.notifier).sendMessage(
                          widget.chat.id,
                          '📷 Image: ${picked.name}',
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
                    ref.read(chatListProvider.notifier).sendMessage(
                          widget.chat.id,
                          '📷 Photo: ${picked.name}',
                        );
                    _scrollToBottom();
                  }
                }),
                _buildAttachOption(
                    Icons.location_on, 'Location', Colors.green, () {
                  Navigator.pop(context);
                  ref.read(chatListProvider.notifier).sendMessage(
                        widget.chat.id,
                        '📍 Location shared',
                      );
                  _scrollToBottom();
                }),
                _buildAttachOption(
                    Icons.person, 'Contact', Colors.blue, () {
                  Navigator.pop(context);
                  ref.read(chatListProvider.notifier).sendMessage(
                        widget.chat.id,
                        '👤 Contact shared',
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
    final chats = ref.watch(chatListProvider);
    final chat = chats.firstWhere((c) => c.id == widget.chat.id);
    final typingMap = ref.watch(typingProvider);
    final someoneTyping = typingMap[chat.id] ?? false;

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
                    userName: chat.userName,
                    avatarPath: chat.avatarPath,
                    radius: 18,
                    isGroup: chat.isGroup,
                    isBroadcast: chat.isBroadcast,
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
                      child: const Icon(Icons.edit,
                          size: 7, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chat.userName,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  // Typing indicator
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
                          chat.isOnline ? 'Online' : 'Offline',
                          style: TextStyle(
                            color:
                                chat.isOnline ? Colors.green : Colors.grey,
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
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: chat.messages.length,
              itemBuilder: (context, index) {
                final message = chat.messages[index];
                return Align(
                  alignment: message.isMe
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color:
                          message.isMe ? Colors.indigo : Colors.white,
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
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                    child: TextField(
                      controller: _messageController,
                      onTap: () {
                        if (_showEmojiPicker) {
                          setState(() => _showEmojiPicker = false);
                        }
                      },
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        hintStyle:
                            TextStyle(color: Colors.grey.shade400),
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
                          icon: const Icon(Icons.attach_file,
                              color: Colors.grey),
                          onPressed: _pickAttachment,
                        ),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: const BoxDecoration(
                      color: Colors.indigo,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.send,
                          color: Colors.white, size: 20),
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