import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart';
import '../providers/real_chat_provider.dart';
import '../models/chat_model.dart';
import 'chat_detail_screen.dart';

class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;
  Timer? _debounce;

  Future<void> _searchUsers(String query) async {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }
    setState(() => _isSearching = true);
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        final api = ref.read(apiClientProvider);
        final results = await api.searchUsers(query.trim());
        if (mounted) {
          setState(() {
            _searchResults = results.cast<Map<String, dynamic>>();
            _isSearching = false;
          });
        }
      } catch (e) {
        debugPrint('[NewChat] Erreur recherche: $e');
        if (mounted) setState(() => _isSearching = false);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _startConversation(Map<String, dynamic> user) async {
    try {
      final api = ref.read(apiClientProvider);
      final result = await api.createConversation(
        participantID: user['alanyaID'] as int,
      );

      debugPrint('[NewChat] Résultat createConversation: $result');
      debugPrint('[NewChat] Clés disponibles: ${result.keys.toList()}');

      // ← Correction : 'conversID' avec majuscule
      final conversId = result['conversID']?.toString() ?? '';
      debugPrint('[NewChat] Conversation créée: $conversId');

      if (conversId.isEmpty) {
        debugPrint('[NewChat] ⚠️ ID vide malgré la réponse du backend !');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Erreur: ID conversation invalide')),
          );
        }
        return;
      }

      final chat = Chat(
        id: conversId,
        userName: user['nom'] ?? user['pseudo'] ?? 'Inconnu',
        isOnline: (user['is_online'] ?? 0) == 1,
        avatarPath: user['avatar_url'],
      );

      if (mounted) {
        await ref.read(realChatProvider.notifier).refresh(api);
        Navigator.pop(context);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatDetailScreen(chat: chat),
          ),
        );
      }
    } catch (e) {
      debugPrint('[NewChat] Erreur création conversation: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible de créer la conversation')),
        );
      }
    }
  }

  void _showNewGroupDialog() {
    final nameController = TextEditingController();
    final List<Map<String, dynamic>> selectedMembers = [];

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('New Group'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    hintText: 'Group name...',
                    prefixIcon: Icon(Icons.group),
                  ),
                ),
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Add members',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.grey),
                  ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 250),
                  child: _searchResults.isEmpty
                      ? const Center(
                          child: Text(
                            'Recherchez des utilisateurs d\'abord',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: _searchResults.length,
                          itemBuilder: (context, index) {
                            final user = _searchResults[index];
                            final isSelected = selectedMembers.any(
                                (m) => m['alanyaID'] == user['alanyaID']);
                            return CheckboxListTile(
                              dense: true,
                              activeColor: Colors.indigo,
                              value: isSelected,
                              onChanged: (val) {
                                setDialogState(() {
                                  if (val == true) {
                                    selectedMembers.add(user);
                                  } else {
                                    selectedMembers.removeWhere((m) =>
                                        m['alanyaID'] == user['alanyaID']);
                                  }
                                });
                              },
                              title: Text(
                                  user['nom'] ?? user['pseudo'] ?? 'Inconnu'),
                              secondary: CircleAvatar(
                                backgroundColor: Colors.indigo.shade50,
                                child: Text(
                                  (user['nom'] ?? user['pseudo'] ?? '?')[0],
                                  style:
                                      const TextStyle(color: Colors.indigo),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                if (selectedMembers.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${selectedMembers.length} member(s) selected',
                      style: const TextStyle(
                        color: Colors.indigo,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                if (nameController.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Please enter a group name')),
                  );
                  return;
                }
                if (selectedMembers.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Please add at least one member')),
                  );
                  return;
                }
                try {
                  final api = ref.read(apiClientProvider);
                  await api.createGroup(
                    participantIDs: selectedMembers
                        .map((m) => m['alanyaID'] as int)
                        .toList(),
                    groupName: nameController.text.trim(),
                  );
                  await ref.read(realChatProvider.notifier).refresh(api);
                  if (mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Groupe "${nameController.text.trim()}" créé !',
                        ),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Erreur création du groupe')),
                    );
                  }
                }
              },
              child: const Text('Create',
                  style: TextStyle(color: Colors.indigo)),
            ),
          ],
        ),
      ),
    );
  }

  void _showNewBroadcastDialog() {
    final nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Broadcast'),
        content: TextField(
          controller: nameController,
          decoration:
              const InputDecoration(hintText: 'Broadcast name...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (nameController.text.trim().isNotEmpty) {
                ref.read(chatListProvider.notifier).addChat(
                      nameController.text.trim(),
                      isBroadcast: true,
                    );
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        'Broadcast "${nameController.text.trim()}" créé !'),
                  ),
                );
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.indigo,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'New Chat',
          style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold),
        ),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.indigo,
            child: TextField(
              controller: _searchController,
              onChanged: (value) {
                setState(() {});
                _searchUsers(value);
              },
              decoration: InputDecoration(
                hintText: 'Search names or numbers...',
                prefixIcon: _isSearching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.grey,
                          ),
                        ),
                      )
                    : const Icon(Icons.search, color: Colors.grey),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                _buildActionTile(
                    Icons.group_add, 'New Group', _showNewGroupDialog),
                _buildActionTile(Icons.campaign, 'New Broadcast',
                    _showNewBroadcastDialog),
                const Padding(
                  padding: EdgeInsets.only(left: 20, top: 16, bottom: 8),
                  child: Text(
                    'Contacts on Talky',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.grey),
                  ),
                ),
                if (_searchController.text.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        'Recherchez un utilisateur par nom ou numéro',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade400),
                      ),
                    ),
                  )
                else if (_searchResults.isEmpty && !_isSearching)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        'Aucun utilisateur trouvé pour "${_searchController.text}"',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade400),
                      ),
                    ),
                  )
                else
                  ..._searchResults.map((user) {
                    final name = user['nom'] ?? user['pseudo'] ?? 'Inconnu';
                    final isOnline = (user['is_online'] ?? 0) == 1;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 8),
                      leading: CircleAvatar(
                        radius: 24,
                        backgroundColor: Colors.indigo.shade50,
                        backgroundImage: user['avatar_url'] != null
                            ? NetworkImage(user['avatar_url'])
                            : null,
                        child: user['avatar_url'] == null
                            ? Text(
                                name[0].toUpperCase(),
                                style: const TextStyle(
                                    color: Colors.indigo,
                                    fontWeight: FontWeight.bold),
                              )
                            : null,
                      ),
                      title: Text(
                        name,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      subtitle: Text(
                        isOnline ? 'Online' : 'Available',
                        style: TextStyle(
                          color: isOnline ? Colors.green : Colors.grey,
                        ),
                      ),
                      onTap: () => _startConversation(user),
                    );
                  }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile(IconData icon, String text, VoidCallback onTap) {
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: Colors.grey.shade100,
        child: Icon(icon, color: Colors.black87),
      ),
      title: Text(text,
          style:
              const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      onTap: onTap,
    );
  }
}