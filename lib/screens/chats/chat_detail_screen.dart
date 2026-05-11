import 'dart:async';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import '../../config/app_config.dart';
import '../../services/api_service.dart';
import '../../services/socket_service.dart';
import '../../services/upload_service.dart';
import '../../models/message.dart';
import '../calls/ongoing_call_screen.dart';

class ChatDetailScreen extends StatefulWidget {
  final int conversationId;
  final String conversationName;
  final int? otherParticipantId;
  final bool initialOnline;

  const ChatDetailScreen({
    super.key,
    required this.conversationId,
    required this.conversationName,
    this.otherParticipantId,
    this.initialOnline = false,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final _api = ApiService();
  final _socket = SocketService();
  final _upload = UploadService();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  // Enregistreur vocal (fonctionne sur web et mobile)
  final _recorder = AudioRecorder();

  List<Message> _messages = [];
  bool _isLoading = true;
  String? _error;
  bool _isSending = false;    // Envoi media en cours

  // Présence de l'interlocuteur
  late bool _otherIsOnline;

  // "... est en train d'écrire"
  bool _isTyping = false;

  // Enregistrement vocal
  bool _isRecording = false;
  int _recordSeconds = 0;
  // startStream() capture les bytes en direct — fonctionne web + mobile,
  // sans blob URL ni accès filesystem.
  final List<int> _audioChunks = [];
  StreamSubscription<Uint8List>? _recordSub;

  @override
  void initState() {
    super.initState();
    _otherIsOnline = widget.initialOnline;
    _setupSocket();
    _loadMessages();
  }

  // ─── CHARGEMENT DES MESSAGES ─────────────────────────────────────────────

  Future<void> _loadMessages() async {
    try {
      setState(() { _isLoading = true; _error = null; });
      final msgs = await _api.getMessages(widget.conversationId);
      msgs.sort((a, b) => a.sentAt.compareTo(b.sentAt));
      setState(() { _messages = msgs; _isLoading = false; });
      _scrollToBottom();
    } catch (e) {
      setState(() { _error = 'Erreur de chargement.\n$e'; _isLoading = false; });
    }
  }

  // ─── SOCKET ──────────────────────────────────────────────────────────────

  void _setupSocket() {
    _socket.connect();
    _socket.joinConversation(widget.conversationId);

    // Nouveau message en temps réel
    _socket.onMessageReceived = (Message newMsg) {
      if (newMsg.conversationId != widget.conversationId) return;
      setState(() {
        final exists = _messages.any((m) => m.id == newMsg.id);
        if (!exists) {
          _messages.add(newMsg);
          _messages.sort((a, b) => a.sentAt.compareTo(b.sentAt));
        }
        _isTyping = false;
      });
      _scrollToBottom();
    };

    // ── CORRECTION PRINCIPALE DES COCHES ────────────────────────────────
    // Le backend émet cet event DANS DEUX CAS :
    //   1. MOI j'ouvre le chat → readBy = mon ID → ça marque les messages
    //      de l'AUTRE comme lus. Je ne dois PAS changer mes propres coches.
    //   2. L'AUTRE ouvre le chat → readBy = ID de l'autre → mes messages
    //      ont été lus. Je DOIS mettre mes coches en bleu.
    _socket.onMessageStatusUpdated = (int convId, int status, int readBy) {
      if (convId != widget.conversationId) return;

      // Cas 2 : quelqu'un d'autre a lu → mettre mes messages à jour
      if (readBy != AppConfig.currentUserId) {
        setState(() {
          _messages = _messages.map((m) {
            // On ne met à jour que MES messages (envoyés par moi)
            if (m.senderId == AppConfig.currentUserId && m.status < status) {
              return m.copyWith(status: status);
            }
            return m;
          }).toList();
        });
      }
      // Cas 1 : c'est MOI qui ai lu → on ne touche à rien côté coches
    };

    _socket.onTypingStarted = (userId) {
      if (userId != widget.otherParticipantId) return;
      setState(() => _isTyping = true);
    };
    _socket.onTypingStopped = (userId) {
      if (userId != widget.otherParticipantId) return;
      setState(() => _isTyping = false);
    };

    _socket.onPresenceUpdated = (userId, isOnline) {
      if (userId != widget.otherParticipantId) return;
      setState(() => _otherIsOnline = isOnline);
    };
  }

  // ─── ENVOI DE MESSAGES ───────────────────────────────────────────────────

  void _sendText() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    _socket.sendMessage(
      conversationId: widget.conversationId,
      content: text,
      type: MessageType.text,
    );
  }

  /// Ouvre un sélecteur de fichier, upload, puis envoie le message.
  Future<void> _pickAndSendFile({required bool imageOnly}) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: imageOnly ? FileType.image : FileType.any,
        allowMultiple: false,
        withData: true, // Nécessaire pour récupérer les bytes sur le web
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) return;

      final ext = file.extension?.toLowerCase() ?? '';
      final isImg = ['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext);
      final isVid = ['mp4', 'mov', 'avi', 'webm'].contains(ext);
      final type = isImg
          ? MessageType.image
          : isVid
              ? MessageType.video
              : MessageType.file;

      setState(() => _isSending = true);

      String mediaUrl;
      try {
        mediaUrl = await _upload.uploadBytes(
          bytes,
          file.name,
          _mimeFromExt(ext),
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Upload impossible : $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        setState(() => _isSending = false);
        return;
      }

      _socket.sendMessage(
        conversationId: widget.conversationId,
        content: file.name,  // Le texte affiché sous le média
        type: type,
        mediaUrl: mediaUrl,
        mediaName: file.name,
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  // ─── ENREGISTREMENT VOCAL ────────────────────────────────────────────────

  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permission micro refusée')),
        );
      }
      return;
    }

    // Vide le buffer de l'enregistrement précédent
    _audioChunks.clear();
    setState(() { _isRecording = true; _recordSeconds = 0; });

    // startStream() donne un Stream<Uint8List> de chunks audio.
    // Fonctionne identiquement sur web et mobile — pas de blob URL,
    // pas de fichier temporaire à gérer.
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.opus,   // opus/webm : compatible web + mobile
        sampleRate: 16000,            // 16 kHz suffit pour la voix
        numChannels: 1,               // mono
      ),
    );

    // On écoute le stream et on accumule les chunks
    _recordSub = stream.listen(
      (chunk) => _audioChunks.addAll(chunk),
      onError: (e) => print('[Record] Erreur stream : $e'),
    );

    _tickDuration();
  }

  Future<void> _stopAndSendRecording() async {
    if (!_isRecording) return;

    final duration = _recordSeconds;
    setState(() => _isRecording = false);

    // Stoppe l'enregistrement et le stream
    await _recorder.stop();
    await _recordSub?.cancel();
    _recordSub = null;

    if (_audioChunks.isEmpty) return;

    final bytes = Uint8List.fromList(_audioChunks);
    final filename = 'voice_${DateTime.now().millisecondsSinceEpoch}.ogg';

    setState(() => _isSending = true);
    try {
      // Upload du fichier audio
      final mediaUrl = await _upload.uploadBytes(
        bytes,
        filename,
        'audio/ogg',
      );

      // Envoi du message vocal via socket
      _socket.sendMessage(
        conversationId: widget.conversationId,
        content: '🎤 Message vocal',
        type: MessageType.audio,
        mediaUrl: mediaUrl,
        mediaName: filename,
        mediaDuration: duration,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erreur envoi vocal : $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() { _isSending = false; _recordSeconds = 0; });
    }
  }

  void _cancelRecording() async {
    await _recorder.stop();
    await _recordSub?.cancel();
    _recordSub = null;
    _audioChunks.clear();
    setState(() => _isRecording = false);
  }

  Future<void> _tickDuration() async {
    while (_isRecording && mounted) {
      await Future.delayed(const Duration(seconds: 1));
      if (_isRecording && mounted) setState(() => _recordSeconds++);
    }
  }

  String _formatDuration(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _mimeFromExt(String ext) {
    const map = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
      'gif': 'image/gif', 'webp': 'image/webp',
      'mp4': 'video/mp4', 'mov': 'video/quicktime', 'webm': 'video/webm',
      'pdf': 'application/pdf', 'doc': 'application/msword',
      'mp3': 'audio/mpeg', 'ogg': 'audio/ogg',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _socket.onMessageReceived = null;
    _socket.onMessageStatusUpdated = null;
    _socket.onTypingStarted = null;
    _socket.onTypingStopped = null;
    _socket.onPresenceUpdated = null;
    _recorder.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ─── BUILD ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.indigo.shade100,
              child: Text(
                widget.conversationName.isNotEmpty
                    ? widget.conversationName[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                    color: Colors.indigo, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.conversationName,
                    style: const TextStyle(
                        color: Colors.black,
                        fontSize: 15,
                        fontWeight: FontWeight.bold)),
                if (_isTyping)
                  const Text('en train d\'écrire...',
                      style: TextStyle(color: Colors.grey, fontSize: 11))
                else if (_otherIsOnline)
                  const Text('En ligne',
                      style: TextStyle(color: Colors.green, fontSize: 11))
                else
                  const Text('Hors ligne',
                      style: TextStyle(color: Colors.grey, fontSize: 11)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam, color: Colors.indigo),
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => OngoingCallScreen(
                        callerName: widget.conversationName,
                        isVideoCall: true))),
          ),
          IconButton(
            icon: const Icon(Icons.call, color: Colors.indigo),
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => OngoingCallScreen(
                        callerName: widget.conversationName,
                        isVideoCall: false))),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (_isSending)
            Container(
              width: double.infinity,
              color: Colors.indigo.shade50,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('Envoi en cours...',
                      style: TextStyle(fontSize: 12, color: Colors.indigo)),
                ],
              ),
            ),
          Expanded(child: _buildMessageList()),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Colors.indigo));
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error!, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _loadMessages,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo),
            child: const Text('Réessayer',
                style: TextStyle(color: Colors.white)),
          ),
        ]),
      );
    }
    if (_messages.isEmpty) {
      return const Center(
        child: Text('Aucun message.\nEnvoie le premier !',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        final isMe = msg.senderId == AppConfig.currentUserId;
        return _MessageBubble(msg: msg, isMe: isMe);
      },
    );
  }

  // ─── BARRE DE SAISIE ─────────────────────────────────────────────────────

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 10,
              offset: const Offset(0, -4))
        ],
      ),
      child: SafeArea(
        child: _isRecording ? _buildRecordingBar() : _buildNormalBar(),
      ),
    );
  }

  Widget _buildNormalBar() {
    return Row(
      children: [
        // Bouton pièce jointe → bottom sheet de choix
        IconButton(
          icon: const Icon(Icons.add_circle_outline, color: Colors.indigo, size: 28),
          onPressed: _showAttachmentSheet,
        ),
        // Champ de texte
        Expanded(
          child: TextField(
            controller: _textController,
            maxLines: 4,
            minLines: 1,
            decoration: InputDecoration(
              hintText: 'Message...',
              hintStyle: TextStyle(color: Colors.grey.shade400),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: const Color(0xFFF0F2F5),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            ),
            onSubmitted: (_) => _sendText(),
          ),
        ),
        const SizedBox(width: 6),
        // Bouton envoyer (texte) ou micro (vide)
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _textController,
          builder: (_, value, __) {
            final hasText = value.text.trim().isNotEmpty;
            return hasText
                ? _sendButton()
                : _micButton();
          },
        ),
      ],
    );
  }

  Widget _buildRecordingBar() {
    return Row(
      children: [
        // Annuler
        IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          onPressed: _cancelRecording,
        ),
        // Durée
        Expanded(
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                    color: Colors.red, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                _formatDuration(_recordSeconds),
                style: const TextStyle(
                    color: Colors.red,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              const Text('Enregistrement...',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
            ],
          ),
        ),
        // Envoyer
        GestureDetector(
          onTap: _stopAndSendRecording,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
                color: Colors.indigo, shape: BoxShape.circle),
            child: const Icon(Icons.send, color: Colors.white, size: 20),
          ),
        ),
      ],
    );
  }

  Widget _sendButton() {
    return GestureDetector(
      onTap: _sendText,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration:
            const BoxDecoration(color: Colors.indigo, shape: BoxShape.circle),
        child: const Icon(Icons.send, color: Colors.white, size: 20),
      ),
    );
  }

  Widget _micButton() {
    return GestureDetector(
      onTap: _startRecording,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration:
            const BoxDecoration(color: Colors.indigo, shape: BoxShape.circle),
        child: const Icon(Icons.mic, color: Colors.white, size: 20),
      ),
    );
  }

  void _showAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _attachOption(
                    icon: Icons.image,
                    color: Colors.purple,
                    label: 'Photo',
                    onTap: () {
                      Navigator.pop(context);
                      _pickAndSendFile(imageOnly: true);
                    },
                  ),
                  _attachOption(
                    icon: Icons.insert_drive_file,
                    color: Colors.blue,
                    label: 'Fichier',
                    onTap: () {
                      Navigator.pop(context);
                      _pickAndSendFile(imageOnly: false);
                    },
                  ),
                  _attachOption(
                    icon: Icons.videocam,
                    color: Colors.red,
                    label: 'Vidéo',
                    onTap: () {
                      Navigator.pop(context);
                      _pickAndSendFile(imageOnly: false);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _attachOption({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

// ─── BULLE DE MESSAGE ─────────────────────────────────────────────────────────

class _MessageBubble extends StatefulWidget {
  final Message msg;
  final bool isMe;
  const _MessageBubble({required this.msg, required this.isMe});

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  final _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _isPlaying = state == PlayerState.playing);
    });
    _audioPlayer.onPositionChanged.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _audioPlayer.onDurationChanged.listen((dur) {
      if (mounted) setState(() => _duration = dur);
    });
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() { _isPlaying = false; _position = Duration.zero; });
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _toggleAudio() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      final url = widget.msg.mediaUrl;
      if (url == null) return;
      if (_position > Duration.zero) {
        await _audioPlayer.resume();
      } else {
        await _audioPlayer.play(UrlSource(url));
      }
    }
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final isMe = widget.isMe;
    final msg = widget.msg;
    final time =
        '${msg.sentAt.hour}:${msg.sentAt.minute.toString().padLeft(2, '0')}';

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: isMe ? Colors.indigo : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: isMe ? const Radius.circular(18) : Radius.zero,
            bottomRight: isMe ? Radius.zero : const Radius.circular(18),
          ),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 4,
                offset: const Offset(0, 2))
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: isMe ? const Radius.circular(18) : Radius.zero,
            bottomRight: isMe ? Radius.zero : const Radius.circular(18),
          ),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              // Nom expéditeur (messages reçus uniquement)
              if (!isMe)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Text(msg.displayName,
                      style: TextStyle(
                          color: Colors.indigo.shade700,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ),

              // Corps du message selon le type
              _buildContent(msg, isMe),

              // Heure + statut
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 10, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(time,
                        style: TextStyle(
                            color: isMe ? Colors.white60 : Colors.black38,
                            fontSize: 10)),
                    if (isMe) ...[
                      const SizedBox(width: 4),
                      _statusIcon(msg.status, isMe),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(Message msg, bool isMe) {
    switch (msg.type) {
      // ── IMAGE ────────────────────────────────────────────────────────
      case MessageType.image:
        if (msg.mediaUrl != null) {
          return GestureDetector(
            onTap: () => _openImageFullscreen(msg.mediaUrl!),
            child: Image.network(
              msg.mediaUrl!,
              width: 220,
              height: 180,
              fit: BoxFit.cover,
              loadingBuilder: (_, child, progress) => progress == null
                  ? child
                  : Container(
                      width: 220,
                      height: 180,
                      color: Colors.grey.shade200,
                      child: const Center(
                          child: CircularProgressIndicator(strokeWidth: 2))),
              errorBuilder: (_, __, ___) => _mediaErrorWidget(isMe),
            ),
          );
        }
        return _mediaErrorWidget(isMe);

      // ── AUDIO / VOCAL ────────────────────────────────────────────────
      case MessageType.audio:
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                padding: EdgeInsets.zero,
                icon: Icon(_isPlaying ? Icons.pause_circle : Icons.play_circle,
                    color: isMe ? Colors.white : Colors.indigo,
                    size: 38),
                onPressed: _toggleAudio,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Barre de progression
                    SliderTheme(
                      data: SliderThemeData(
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 5),
                        trackHeight: 3,
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 10),
                        activeTrackColor:
                            isMe ? Colors.white : Colors.indigo,
                        inactiveTrackColor:
                            isMe ? Colors.white38 : Colors.indigo.shade100,
                        thumbColor:
                            isMe ? Colors.white : Colors.indigo,
                      ),
                      child: Slider(
                        value: (_duration.inMilliseconds > 0)
                            ? _position.inMilliseconds /
                                _duration.inMilliseconds
                            : 0,
                        onChanged: (v) async {
                          final pos = Duration(
                              milliseconds:
                                  (v * _duration.inMilliseconds).round());
                          await _audioPlayer.seek(pos);
                        },
                      ),
                    ),
                    Text(
                      '${_fmtDuration(_position)} / ${_fmtDuration(_duration)}',
                      style: TextStyle(
                          fontSize: 10,
                          color: isMe ? Colors.white60 : Colors.black45),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

      // ── VIDEO ────────────────────────────────────────────────────────
      case MessageType.video:
        return GestureDetector(
          onTap: () {
            // TODO: ouvrir lecteur vidéo
          },
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 220,
                height: 160,
                color: Colors.black,
                child: const Icon(Icons.movie, color: Colors.white54, size: 48),
              ),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow,
                    color: Colors.white, size: 32),
              ),
            ],
          ),
        );

      // ── FICHIER ──────────────────────────────────────────────────────
      case MessageType.file:
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_drive_file,
                  color: isMe ? Colors.white70 : Colors.indigo, size: 36),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(msg.mediaName ?? msg.content ?? 'Fichier',
                        style: TextStyle(
                            color: isMe ? Colors.white : Colors.black87,
                            fontSize: 14,
                            fontWeight: FontWeight.w500),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text('Appuie pour télécharger',
                        style: TextStyle(
                            color: isMe ? Colors.white54 : Colors.black38,
                            fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        );

      // ── TEXTE (défaut) ───────────────────────────────────────────────
      default:
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(
            msg.content ?? '',
            style: TextStyle(
                color: isMe ? Colors.white : Colors.black87, fontSize: 15),
          ),
        );
    }
  }

  Widget _mediaErrorWidget(bool isMe) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image,
              color: isMe ? Colors.white54 : Colors.grey, size: 28),
          const SizedBox(width: 8),
          Text('Média indisponible',
              style: TextStyle(
                  color: isMe ? Colors.white54 : Colors.grey, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _statusIcon(int status, bool isMe) {
    switch (status) {
      case 3:
        // Lu → deux coches bleues
        return const Icon(Icons.done_all, size: 14, color: Colors.lightBlueAccent);
      case 2:
        // Distribué → deux coches grises
        return const Icon(Icons.done_all, size: 14, color: Colors.white60);
      default:
        // Envoyé → une coche grise
        return const Icon(Icons.done, size: 14, color: Colors.white60);
    }
  }

  void _openImageFullscreen(String url) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black,
            leading: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context))),
        body: Center(
          child: InteractiveViewer(
            child: Image.network(url, fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(
                    Icons.broken_image, color: Colors.white, size: 64)),
          ),
        ),
      ),
    ));
  }
}