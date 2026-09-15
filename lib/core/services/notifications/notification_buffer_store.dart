import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../secure_storage_guard.dart';

/// Buffer messages notification chiffré (remplace SharedPreferences en clair).
class NotificationBufferStore {
  NotificationBufferStore._();

  static const _storage = FlutterSecureStorage(
    aOptions: kSecureStorageAndroidOptions,
  );
  static const _maxMessages = 7;

  static Future<void> _appendChain = Future<void>.value();

  static String _key(int conversationId) => 'notif_buf_$conversationId';

  static Future<List<Map<String, String>>> read(int conversationId) async {
    final raw = await SecureStorageGuard.readString(
      _storage,
      _key(conversationId),
    );
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map((e) => Map<String, String>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<Map<String, String>>> append({
    required int conversationId,
    required String sender,
    required String body,
    String avatar = '',
  }) async {
    final completer = Completer<List<Map<String, String>>>();
    final previous = _appendChain;
    _appendChain = previous.then((_) async {
      try {
        completer.complete(
          await _appendUnlocked(
            conversationId: conversationId,
            sender: sender,
            body: body,
            avatar: avatar,
          ),
        );
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  static Future<List<Map<String, String>>> _appendUnlocked({
    required int conversationId,
    required String sender,
    required String body,
    String avatar = '',
  }) async {
    final messages = await read(conversationId);
    messages.add({
      'sender': sender,
      'body': body,
      'ts': DateTime.now().toUtc().toIso8601String(),
      // Photo de l'auteur de CETTE ligne : en groupe, chaque ligne a la sienne.
      // Clé omise si vide — les entrées écrites avant cette version se relisent
      // donc sans changement.
      if (avatar.isNotEmpty) 'avatar': avatar,
    });
    final trimmed = messages.length > _maxMessages
        ? messages.sublist(messages.length - _maxMessages)
        : messages;
    try {
      await SecureStorageGuard.writeString(
        _storage,
        _key(conversationId),
        jsonEncode(trimmed),
      );
    } catch (e) {
      // Un buffer de notification est jetable : mieux vaut afficher la
      // notification avec la liste en mémoire que faire échouer le handler FCM.
      debugPrint('[NotificationBuffer] écriture conv=$conversationId échouée : $e');
    }
    return trimmed;
  }

  static Future<void> clear(int conversationId) async {
    final previous = _appendChain;
    _appendChain = previous.then((_) async {
      await SecureStorageGuard.deleteKey(_storage, _key(conversationId));
    });
    await _appendChain;
  }

  /// Supprime les anciens buffers SharedPreferences en clair (migration 3.4).
  static Future<void> purgeLegacySharedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where(
        (k) => k.startsWith('notif_msgs_') || k.startsWith('notif_buf_'),
      );
      for (final key in keys) {
        await prefs.remove(key);
      }
    } catch (_) {
      // Best-effort.
    }
  }

  static Future<void> clearAll() async {
    try {
      await purgeLegacySharedPreferences();
    } catch (_) {}
  }

  /// Réinitialise la chaîne de verrou (tests uniquement).
  static void resetAppendChainForTest() {
    _appendChain = Future<void>.value();
  }
}
