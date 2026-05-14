import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart';
import '../models/chat_model.dart';
import 'chat_detail_screen.dart';

class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final TextEditingController _searchController = TextEditingController();

  void _showNewGroupDialog() {
    final nameController = TextEditingController();
    final List<Chat> selectedMembers = [];

    showDialog(
      context: context,
      builder: (context) {
        final allChats = ref.read(chatListProvider)
            .where((c) => !c.isGroup && !c.isBroadcast)
            .toList();

        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('New Group'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Nom du groupe
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
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Liste des contacts sélectionnables
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 250),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: allChats.length,
                      itemBuilder: (context, index) {
                        final chat = allChats[index];
                        final isSelected = selectedMembers
                            .any((m) => m.id == chat.id);
                        return CheckboxListTile(
                          dense: true,
                          activeColor: Colors.indigo,
                          value: isSelected,
                          onChanged: (val) {
                            setDialogState(() {
                              if (val == true) {
                                selectedMembers.add(chat);
                              } else {
                                selectedMembers
                                    .removeWhere((m) => m.id == chat.id);
                              }
                            });
                          },
                          title: Text(chat.userName),
                          secondary: CircleAvatar(
                            backgroundColor: Colors.indigo.shade50,
                            child: Text(
                              chat.userName[0],
                              style: const TextStyle(color: Colors.indigo),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Aperçu des membres sélectionnés
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
                onPressed: () {
                  if (nameController.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please enter a group name')),
                    );
                    return;
                  }
                  if (selectedMembers.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please add at least one member')),
                    );
                    return;
                  }
                  ref.read(chatListProvider.notifier).addChat(
                        nameController.text.trim(),
                        isGroup: true,
                      );
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Group "${nameController.text.trim()}" created with ${selectedMembers.length} member(s)!',
                      ),
                    ),
                  );
                },
                child: const Text(
                  'Create',
                  style: TextStyle(color: Colors.indigo),
                ),
              ),
            ],
          ),
        );
      },
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
          decoration: const InputDecoration(hintText: 'Broadcast name...'),
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
                  SnackBar(content: Text('Broadcast "${nameController.text.trim()}" created!')),
                );
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showNewContactDialog() {
    final nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Contact'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(hintText: 'Contact name...'),
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
                    );
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Contact "${nameController.text.trim()}" added!')),
                );
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(chatListProvider);
    final query = _searchController.text.toLowerCase().trim();
    final filtered = query.isEmpty
        ? chats
        : chats
            .where((c) => c.userName.toLowerCase().contains(query))
            .toList();

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
              color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.indigo,
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search names or numbers...',
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
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
                _buildActionTile(Icons.group_add, 'New Group', _showNewGroupDialog),
                _buildActionTile(Icons.campaign, 'New Broadcast', _showNewBroadcastDialog),
                _buildActionTile(Icons.person_add, 'New Contact', _showNewContactDialog),
                const Padding(
                  padding: EdgeInsets.only(left: 20, top: 16, bottom: 8),
                  child: Text(
                    'Contacts on Talky',
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
                  ),
                ),
                ...filtered.map((chat) {
                  return ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    leading: CircleAvatar(
                      radius: 24,
                      backgroundColor: Colors.indigo.shade50,
                      child: Text(
                        chat.userName[0],
                        style: const TextStyle(
                            color: Colors.indigo, fontWeight: FontWeight.bold),
                      ),
                    ),
                    title: Text(
                      chat.userName,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    subtitle: Text(
                      chat.isOnline ? 'Online' : 'Available',
                      style: const TextStyle(color: Colors.grey),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ChatDetailScreen(chat: chat),
                        ),
                      );
                    },
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: Colors.grey.shade100,
        child: Icon(icon, color: Colors.black87),
      ),
      title: Text(text,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      onTap: onTap,
    );
  }
}