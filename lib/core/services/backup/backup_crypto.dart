import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Signature du format, en tête de chaque archive de sauvegarde.
const String kBackupMagic = 'ALNB';

/// Version du conteneur. Une évolution incompatible l'incrémente, pour que la
/// restauration refuse proprement plutôt que de lire de travers.
const int kBackupFormatVersion = 1;

/// En-tête **en clair** posé devant le contenu chiffré.
///
/// ── Pourquoi le numéro de version de clé (`kid`) est indispensable ──
///
/// Fuite, changement d'hébergeur, simple hygiène : un secret serveur finit
/// toujours par devoir être remplacé. Si les archives ne portent aucune
/// indication de la clé qui les a chiffrées, ce remplacement rend **toutes les
/// sauvegardes existantes illisibles d'un coup**, sans recours ni
/// avertissement.
///
/// Avec le `kid`, la rotation se réduit à insérer un secret et à le marquer
/// courant : les nouvelles sauvegardes l'emploient, les anciennes restent
/// lisibles puisque le serveur sert toujours les anciens numéros. Retirer une
/// version signifie seulement *cesser d'écrire avec*, jamais *cesser de
/// servir*.
///
/// L'en-tête est en clair parce qu'il doit répondre à « comment déchiffrer
/// ceci ? » **sans détenir la clé** — c'est ce qui permet à l'écran de
/// restauration d'annoncer « version de clé inconnue » avant de télécharger
/// huit mégaoctets pour rien.
class BackupHeader {
  final String magic;
  final int formatVersion;

  /// Numéro de version de la clé ayant chiffré ce contenu.
  final int kid;

  /// Compte propriétaire. Informatif : la vraie liaison est cryptographique,
  /// une archive du compte A restant indéchiffrable pour B.
  final int alanyaID;

  /// Nonce AES-GCM, 12 octets.
  final Uint8List nonce;

  /// Version du schéma de la base contenue. La restauration doit **refuser**
  /// une base plus récente que l'application : l'ouvrir la corromprait.
  final int schemaVersion;

  const BackupHeader({
    this.magic = kBackupMagic,
    this.formatVersion = kBackupFormatVersion,
    required this.kid,
    required this.alanyaID,
    required this.nonce,
    required this.schemaVersion,
  });

  bool get isSupported =>
      magic == kBackupMagic && formatVersion == kBackupFormatVersion;

  Map<String, dynamic> toJson() => {
        'magic': magic,
        'formatVersion': formatVersion,
        'kid': kid,
        'alanyaID': alanyaID,
        'nonce': base64Encode(nonce),
        'schemaVersion': schemaVersion,
      };

  factory BackupHeader.fromJson(Map<String, dynamic> json) => BackupHeader(
        magic: json['magic']?.toString() ?? '',
        formatVersion: _asInt(json['formatVersion']) ?? 0,
        kid: _asInt(json['kid']) ?? 0,
        alanyaID: _asInt(json['alanyaID']) ?? 0,
        nonce: base64Decode(json['nonce']?.toString() ?? ''),
        schemaVersion: _asInt(json['schemaVersion']) ?? 0,
      );

  /// Sérialisation : `ALNB` + longueur de l'en-tête sur 4 octets + en-tête
  /// JSON. Un préfixe de longueur explicite plutôt qu'un séparateur — un
  /// séparateur pourrait apparaître dans les octets chiffrés qui suivent.
  Uint8List encode() {
    final body = utf8.encode(jsonEncode(toJson()));
    final out = BytesBuilder()
      ..add(utf8.encode(kBackupMagic))
      ..add(_u32(body.length))
      ..add(body);
    return out.toBytes();
  }

  /// Longueur totale de l'en-tête sérialisé, contenu chiffré exclu.
  static int encodedLength(Uint8List bytes) {
    if (bytes.length < 8) throw const BackupFormatInvalid('archive tronquée');
    return 8 + _readU32(bytes, 4);
  }

  static BackupHeader decode(Uint8List bytes) {
    if (bytes.length < 8) {
      throw const BackupFormatInvalid('archive tronquée');
    }
    final magic = utf8.decode(bytes.sublist(0, 4), allowMalformed: true);
    if (magic != kBackupMagic) {
      throw const BackupFormatInvalid('ce fichier n\'est pas une sauvegarde');
    }
    final length = _readU32(bytes, 4);
    if (bytes.length < 8 + length) {
      throw const BackupFormatInvalid('en-tête incomplet');
    }
    try {
      final json = jsonDecode(utf8.decode(bytes.sublist(8, 8 + length)));
      return BackupHeader.fromJson(json as Map<String, dynamic>);
    } on BackupFormatInvalid {
      rethrow;
    } catch (_) {
      throw const BackupFormatInvalid('en-tête illisible');
    }
  }

  static Uint8List _u32(int v) => Uint8List(4)
    ..[0] = (v >> 24) & 0xFF
    ..[1] = (v >> 16) & 0xFF
    ..[2] = (v >> 8) & 0xFF
    ..[3] = v & 0xFF;

  static int _readU32(Uint8List b, int at) =>
      (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
}

/// Chiffre et déchiffre le contenu d'une sauvegarde.
///
/// La clé n'est **jamais écrite en clair sur le téléphone** : elle est demandée
/// au serveur au moment de sauvegarder, redemandée au moment de restaurer, et
/// oubliée entre les deux. C'est cette dérivation, et non le compte Google,
/// qui rattache une sauvegarde à son propriétaire — une archive du compte A
/// posée dans le Drive de B reste illisible pour B, ce qui est précisément ce
/// qui permet au rattachement de rester souple.
class BackupCrypto {
  final AesGcm _algorithm = AesGcm.with256bits();

  /// Assemble l'archive complète : en-tête en clair, puis contenu chiffré.
  Future<Uint8List> seal({
    required Uint8List plain,
    required List<int> key,
    required int kid,
    required int alanyaID,
    required int schemaVersion,
    List<int>? nonceForTests,
  }) async {
    final nonce = nonceForTests ?? _algorithm.newNonce();
    final header = BackupHeader(
      kid: kid,
      alanyaID: alanyaID,
      nonce: Uint8List.fromList(nonce),
      schemaVersion: schemaVersion,
    );
    final headerBytes = header.encode();

    // L'en-tête sert de données authentifiées : modifier le `kid` ou
    // l'`alanyaID` d'une archive fait alors échouer le déchiffrement au lieu
    // de passer inaperçu.
    final box = await _algorithm.encrypt(
      plain,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: headerBytes,
    );

    return (BytesBuilder()
          ..add(headerBytes)
          ..add(box.cipherText)
          ..add(box.mac.bytes))
        .toBytes();
  }

  /// Déchiffre une archive. L'appelant a lu l'en-tête au préalable pour
  /// obtenir le `kid` et demander la bonne clé au serveur.
  Future<Uint8List> open({
    required Uint8List archive,
    required List<int> key,
  }) async {
    final header = BackupHeader.decode(archive);
    if (!header.isSupported) {
      throw const BackupFormatInvalid('version de format non prise en charge');
    }
    final headerLength = BackupHeader.encodedLength(archive);
    final macLength = _algorithm.macAlgorithm.macLength;
    if (archive.length < headerLength + macLength) {
      throw const BackupFormatInvalid('archive tronquée');
    }

    final cipherText =
        archive.sublist(headerLength, archive.length - macLength);
    final mac = Mac(archive.sublist(archive.length - macLength));

    try {
      final clear = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: header.nonce, mac: mac),
        secretKey: SecretKey(key),
        aad: archive.sublist(0, headerLength),
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      // Mauvaise clé, archive altérée, ou en-tête retouché : indiscernables,
      // et c'est voulu — distinguer les cas renseignerait un attaquant.
      throw const BackupAuthenticationFailed();
    }
  }
}

/// Le fichier n'est pas une sauvegarde Alanya lisible.
class BackupFormatInvalid implements Exception {
  final String reason;
  const BackupFormatInvalid(this.reason);
  @override
  String toString() => 'BackupFormatInvalid($reason)';
}

/// La clé ne correspond pas, ou l'archive a été altérée.
class BackupAuthenticationFailed implements Exception {
  const BackupAuthenticationFailed();
  @override
  String toString() => 'BackupAuthenticationFailed';
}

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '');
}
