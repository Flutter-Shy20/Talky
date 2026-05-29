import 'package:flutter/material.dart';
import '../../core/extensions/context_extensions.dart';

class ContactsScreen extends StatelessWidget {
  const ContactsScreen({super.key});

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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.selectContact,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              context.l10n.contactsCount(254),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search, color: Colors.white),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onPressed: () {},
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: 20,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildActionTile(Icons.group_add, context.l10n.newGroup);
          }
          if (index == 1) {
            return _buildActionTile(Icons.person_add, context.l10n.newContact);
          }

          final contactIndex = index - 2;
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 8,
            ),
            leading: CircleAvatar(
              radius: 24,
              backgroundColor: Colors.indigo.shade50,
              child: Text(
                'C$contactIndex',
                style: const TextStyle(
                  color: Colors.indigo,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            title: Text(
              '${context.l10n.contactsTitle} $contactIndex',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            subtitle: Text(
              context.l10n.defaultStatus,
              style: const TextStyle(color: Colors.grey),
            ),
            onTap: () {
              Navigator.pop(
                context,
              ); // Would navigate to chat detail with this user
            },
          );
        },
      ),
    );
  }

  Widget _buildActionTile(IconData icon, String text) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: Colors.indigo,
        child: Icon(icon, color: Colors.white),
      ),
      title: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      ),
      onTap: () {},
    );
  }
}
