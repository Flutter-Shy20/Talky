import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/backup/server_backup_key_provider.dart';

/// Récupération des clés auprès du serveur.
///
/// Le principe éprouvé ici : **une clé douteuse est refusée, jamais
/// contournée**. Chiffrer avec une clé de repli produirait des archives qui
/// n'ont ni la sécurité ni la lisibilité promises, et le problème
/// n'apparaîtrait qu'à la restauration.
void main() {
  String ok({int kid = 1, int length = 32}) => jsonEncode({
        'kid': kid,
        'key': base64Encode(List<int>.filled(length, 7)),
      });

  test('une réponse conforme rend la clé et sa version', () async {
    final provider = ServerBackupKeyProvider((_) async => ok(kid: 3));
    final key = await provider.current();

    expect(key.kid, 3);
    expect(key.bytes, hasLength(32));
  });

  test('la version demandée est bien celle de la route', () async {
    final paths = <String>[];
    final provider = ServerBackupKeyProvider((path) async {
      paths.add(path);
      return ok();
    });

    await provider.current();
    await provider.byKid(7);

    // C'est ce couple de routes qui rend la rotation de secret possible.
    expect(paths, ['/backup/key', '/backup/key/7']);
  });

  test('un serveur injoignable interrompt la sauvegarde, sans repli', () async {
    final provider = ServerBackupKeyProvider(
      (_) async => throw Exception('réseau coupé'),
    );
    expect(provider.current(), throwsA(isA<BackupKeyUnavailable>()));
  });

  test('une clé de la mauvaise taille est refusée', () async {
    // AES-256 attend 32 octets. Accepter autre chose signalerait un serveur
    // mal configuré et produirait des archives illisibles par la suite.
    final provider = ServerBackupKeyProvider((_) async => ok(length: 16));
    expect(provider.current(), throwsA(isA<BackupKeyUnavailable>()));
  });

  test('une réponse illisible ou incomplète est refusée', () async {
    expect(
      ServerBackupKeyProvider((_) async => 'pas du json').current(),
      throwsA(isA<BackupKeyUnavailable>()),
    );
    expect(
      ServerBackupKeyProvider((_) async => '{"kid":1}').current(),
      throwsA(isA<BackupKeyUnavailable>()),
    );
    expect(
      ServerBackupKeyProvider((_) async => '{"key":"AAAA"}').current(),
      throwsA(isA<BackupKeyUnavailable>()),
    );
  });
}
