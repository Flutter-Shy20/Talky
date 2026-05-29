import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../talky_api_client.dart';
import '../../talky_models.dart';
import 'chat_detail_screen.dart';
import '../../core/extensions/context_extensions.dart';

class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  List<User> _users = [];
  List<User> _filteredUsers = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _searchController.addListener(_filterUsers);
  }

  Future<void> _loadContacts() async {
    setState(() => _isLoading = true);

    try {
      final apiClient = Provider.of<TalkyApiClient>(context, listen: false);
      final data = await apiClient.getContacts();
      final users = data.map((item) {
        if (item is User) return item;
        return User.fromJson(item as Map<String, dynamic>);
      }).toList();
      setState(() {
        _users = users;
        _filteredUsers = users;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  void _filterUsers() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredUsers = _users.where((user) {
        final nom = user.nom.toLowerCase();
        final pseudo = user.pseudo.toLowerCase();
        final phone = user.alanyaPhone.toLowerCase();
        return nom.contains(query) ||
            pseudo.contains(query) ||
            phone.contains(query);
      }).toList();
    });
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
        title: Text(
          context.l10n.newChat,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.indigo,
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: context.l10n.searchNamesOrNumbers,
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
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    children: [
                      _buildActionTile(Icons.group_add, context.l10n.newGroup),
                      _buildActionTile(
                        Icons.campaign,
                        context.l10n.newBroadcast,
                      ),
                      _buildActionTile(
                        Icons.person_add,
                        context.l10n.newContact,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 20,
                          top: 16,
                          bottom: 8,
                        ),
                        child: Text(
                          context.l10n.contactsOnTalky,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                      ..._filteredUsers.map((user) {
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 8,
                          ),
                          leading: CircleAvatar(
                            radius: 24,
                            backgroundColor: Colors.indigo.shade50,
                            child: Text(
                              (user.nom.isNotEmpty
                                  ? user.nom[0].toUpperCase()
                                  : '?'),
                              style: const TextStyle(
                                color: Colors.indigo,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          title: Text(
                            user.nom,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          subtitle: Text(
                            user.isOnline
                                ? context.l10n.online
                                : context.l10n.offline,
                            style: TextStyle(
                              color: user.isOnline ? Colors.green : Colors.grey,
                            ),
                          ),
                          onTap: () async {
                            final apiClient = Provider.of<TalkyApiClient>(
                              context,
                              listen: false,
                            );

                            try {
                              final conv = await apiClient.createConversation(
                                participantID: user.alanyaID,
                              );

                              if (!mounted) return;

                              final conversationId =
                                  conv['conversID'] ??
                                      conv['conversationID'] ??
                                      conv['conversationId'];

                              if (conversationId == null) {
                                throw Exception('Conversation ID not found');
                              }

                              // ✅ Close NewChatScreen first
                              Navigator.of(context).pop();

                              // ✅ Wait for pop animation to finish
                              await Future.delayed(const Duration(milliseconds: 150));

                              if (!mounted) return;

                              // ✅ Open chat screen from root navigator
                              Navigator.of(context, rootNavigator: true).push(
                                MaterialPageRoute(
                                  builder: (_) => ChatDetailScreen(
                                    userName: user.nom,
                                    conversationId: conversationId,
                                    userId: user.alanyaID,
                                  ),
                                ),
                              );
                            } catch (e) {
                              if (!mounted) return;

                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    context.l10n.genericErrorWithMessage(
                                      e.toString(),
                                    ),
                                  ),
                                ),
                              );
                            }
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

  Widget _buildActionTile(IconData icon, String text) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: Colors.grey.shade100,
        child: Icon(icon, color: Colors.black87),
      ),
      title: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      ),
      onTap: () {},
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
}
