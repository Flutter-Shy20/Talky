import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/backup/backup_crypto.dart';

/// Conteneur de sauvegarde : en-tête en clair, contenu chiffré.
///
/// Les scénarios éprouvés ici sont ceux de la restauration : archive tronquée,
/// version de clé inconnue, schéma futur, mauvaise clé. Ils doivent tous
/// produire un refus **lisible**, jamais un plantage ni une lecture de travers.
void main() {
  final crypto = BackupCrypto();

  List<int> key(int seed) => List<int>.filled(32, seed);
  Uint8List content(String s) => Uint8List.fromList(utf8.encode(s));

  Future<Uint8List> seal({
    String body = 'contenu-de-base',
    int kid = 1,
    int alanyaID = 241030112,
    int schemaVersion = 26,
    int keySeed = 7,
  }) =>
      crypto.seal(
        plain: content(body),
        key: key(keySeed),
        kid: kid,
        alanyaID: alanyaID,
        schemaVersion: schemaVersion,
      );

  test('un aller-retour rend exactement le contenu d\'origine', () async {
    final archive = await seal();
    final clear = await crypto.open(archive: archive, key: key(7));
    expect(utf8.decode(clear), 'contenu-de-base');
  });

  test('l\'en-tête se lit sans détenir la clé', () async {
    // C'est ce qui permet à l'écran de restauration d'annoncer « version de
    // clé inconnue » AVANT de télécharger huit mégaoctets pour rien.
    final archive = await seal(kid: 3, schemaVersion: 26);
    final header = BackupHeader.decode(archive);

    expect(header.kid, 3);
    expect(header.alanyaID, 241030112);
    expect(header.schemaVersion, 26);
    expect(header.isSupported, isTrue);
  });

  test('une mauvaise clé est refusée, pas devinée', () async {
    final archive = await seal(keySeed: 7);
    // Une archive du compte A posée dans le Drive de B reste illisible pour B :
    // c'est le chiffrement qui porte le rattachement, pas le compte Google.
    expect(
      () => crypto.open(archive: archive, key: key(9)),
      throwsA(isA<BackupAuthenticationFailed>()),
    );
  });

  test('altérer l\'en-tête fait échouer le déchiffrement', () async {
    final archive = await seal(kid: 1, alanyaID: 111);
    final tampered = Uint8List.fromList(archive);
    // L'en-tête sert de données authentifiées : le retoucher ne peut pas
    // passer inaperçu. On modifie un octet du JSON, après la signature ALNB.
    tampered[20] = tampered[20] ^ 0x01;

    expect(
      () => crypto.open(archive: tampered, key: key(7)),
      throwsA(anyOf(
        isA<BackupAuthenticationFailed>(),
        isA<BackupFormatInvalid>(),
      )),
    );
  });

  test('altérer le contenu chiffré fait échouer le déchiffrement', () async {
    final archive = await seal();
    final tampered = Uint8List.fromList(archive);
    tampered[tampered.length - 20] = tampered[tampered.length - 20] ^ 0xFF;

    expect(
      () => crypto.open(archive: tampered, key: key(7)),
      throwsA(isA<BackupAuthenticationFailed>()),
    );
  });

  test('une archive tronquée est refusée avec un motif lisible', () async {
    final archive = await seal();
    final truncated = archive.sublist(0, archive.length - 8);

    expect(
      () => crypto.open(archive: truncated, key: key(7)),
      throwsA(anyOf(
        isA<BackupFormatInvalid>(),
        isA<BackupAuthenticationFailed>(),
      )),
    );

    // Coupée avant même l'en-tête : le refus doit rester net.
    expect(
      () => BackupHeader.decode(archive.sublist(0, 6)),
      throwsA(isA<BackupFormatInvalid>()),
    );
  });

  test('un fichier quelconque n\'est pas pris pour une sauvegarde', () async {
    final notABackup = Uint8List.fromList(utf8.encode('bonjour tout le monde'));
    expect(
      () => BackupHeader.decode(notABackup),
      throwsA(isA<BackupFormatInvalid>()),
    );
  });

  test('une version de format plus récente est refusée, pas devinée', () {
    final header = BackupHeader.fromJson({
      'magic': kBackupMagic,
      'formatVersion': kBackupFormatVersion + 1,
      'kid': 1,
      'alanyaID': 1,
      'nonce': base64Encode(List<int>.filled(12, 0)),
      'schemaVersion': 26,
    });
    expect(header.isSupported, isFalse);
  });

  test('deux scellages du même contenu donnent des octets différents',
      () async {
    // Nonce tiré à chaque fois : deux sauvegardes identiques ne doivent pas
    // se ressembler sur le Drive de l'inscrit.
    final a = await seal();
    final b = await seal();
    expect(a, isNot(equals(b)));
  });

  test('le kid voyage intact, c\'est lui qui rend la rotation possible',
      () async {
    // Sans lui, remplacer le secret serveur rendrait toutes les sauvegardes
    // existantes illisibles d'un coup.
    for (final kid in [1, 2, 42]) {
      final archive = await seal(kid: kid);
      expect(BackupHeader.decode(archive).kid, kid);
    }
  });
}
