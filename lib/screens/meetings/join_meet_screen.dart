import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../talky_api_client.dart';
import '../../core/services/meeting_service.dart';
import '../../core/extensions/context_extensions.dart';
import 'ongoing_meet_screen.dart';

class JoinMeetScreen extends StatefulWidget {
  const JoinMeetScreen({super.key});

  @override
  State<JoinMeetScreen> createState() => _JoinMeetScreenState();
}

class _JoinMeetScreenState extends State<JoinMeetScreen> {
  final TextEditingController _codeController = TextEditingController();
  bool _isCodeValid = false;
  bool _isJoining = false;

  @override
  void initState() {
    super.initState();
    _codeController.addListener(() {
      setState(() {
        _isCodeValid = _codeController.text.trim().length >= 5;
      });
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _joinMeeting() async {
    setState(() => _isJoining = true);

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final apiClient = Provider.of<TalkyApiClient>(context, listen: false);
      final meetingService = Provider.of<MeetingService>(
        context,
        listen: false,
      );

      final userData = await apiClient.getMe();
      if (!mounted) return;
      final myId = userData['alanyaID'] ?? 0;
      final myName = userData['nom'] ?? userData['pseudo'] ?? '';

      await meetingService.joinByRoom(
        roomCode: _codeController.text.trim(),
        myId: myId,
        myName: myName,
      );

      if (!mounted) return;
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const OngoingMeetScreen()),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(context.l10n.failedToJoinMeeting(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _isJoining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          context.l10n.joinAMeeting,
          style: const TextStyle(color: Colors.black, fontSize: 18),
        ),
        actions: [
          TextButton(
            onPressed: _isCodeValid && !_isJoining ? _joinMeeting : null,
            child: _isJoining
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    context.l10n.join,
                    style: TextStyle(
                      color: _isCodeValid ? Colors.indigo : Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.enterMeetingCodeProvided,
              style: const TextStyle(fontSize: 16, color: Colors.black87),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _codeController,
              decoration: InputDecoration(
                hintText: context.l10n.joinMeetingExample,
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.indigo, width: 2),
                ),
              ),
              style: const TextStyle(fontSize: 18, letterSpacing: 1.2),
            ),
            const SizedBox(height: 32),
            Text(
              context.l10n.joinMeetingHelp,
              style: const TextStyle(
                color: Colors.grey,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
