import 'dart:io';
import 'package:flutter/material.dart';

class ChatAvatar extends StatelessWidget {
  final String userName;
  final String? avatarPath;
  final double radius;
  final bool isGroup;
  final bool isBroadcast;

  const ChatAvatar({
    super.key,
    required this.userName,
    this.avatarPath,
    this.radius = 28,
    this.isGroup = false,
    this.isBroadcast = false,
  });

  @override
  Widget build(BuildContext context) {
    if (avatarPath != null) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: FileImage(File(avatarPath!)),
      );
    }
    if (isGroup) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Colors.teal.shade100,
        child: Icon(Icons.group, color: Colors.teal, size: radius),
      );
    }
    if (isBroadcast) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Colors.orange.shade100,
        child: Icon(Icons.campaign, color: Colors.orange, size: radius),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.indigo.shade100,
      child: Text(
        userName[0].toUpperCase(),
        style: TextStyle(
          color: Colors.indigo,
          fontWeight: FontWeight.bold,
          fontSize: radius * 0.7,
        ),
      ),
    );
  }
}