// Envelope encryption pour les médias — voir MEDIAS_E2EE.md (Alanya-backend).
//
// Le fichier n'est JAMAIS chiffré avec le ratchet 1-à-1 ni le GroupCipher :
// une clé média AES-256 jetable chiffre le blob une seule fois ; seule cette
// clé (petite) voyage ensuite dans le message E2EE, selon le canal (1-à-1 ou
// groupe). Le serveur ne stocke qu'un blob opaque, jamais la clé.
//
// Chiffrement PAR CHUNKS (voir §4.4 du doc) : un gros fichier (vidéo) ne doit
// jamais être chargé entièrement en mémoire (`readAsBytes` sur 200 Mo → OOM
// mobile). Chaque chunk est chiffré indépendamment en AES-256-GCM avec la
// même clé média mais un nonce distinct (dérivé d'un compteur) — jamais deux
// fois le même nonce avec la même clé.
//
// Format du blob (streamable, sans longueur totale à connaître à l'avance) :
//   en-tête (12 octets) : magic "E2C1" (4) | chunkSize BE (4) | streamId BE (4)
//   puis, pour chaque chunk : cipherText (chunkSize ou moins, dernier chunk) | mac (16)
// Le nonce du chunk i = streamId (4) | 0x00000000 (4) | index i BE (4).

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class MediaCipherService {
  static const nonceLength = 12;
  static const _macLength = 16;
  static const _headerLength = 12;
  static const _magic = [0x45, 0x32, 0x43, 0x31]; // "E2C1"

  /// Taille de chunk par défaut pour un envoi réel (1 MiB) : assez gros pour
  /// limiter l'overhead HTTP/multipart, assez petit pour borner la mémoire.
  static const defaultChunkSize = 1 << 20;

  Future<SecretKey> newMediaKey() => AesGcm.with256bits().newSecretKey();

  /// Taille exacte du blob chiffré produit par [encryptFileStreaming] pour un
  /// fichier de [plainLength] octets — nécessaire pour fournir un
  /// Content-Length à la requête HTTP streamée (pas de buffering complet).
  static int encryptedLengthFor(int plainLength, int chunkSize) {
    final numChunks = plainLength == 0 ? 1 : (plainLength / chunkSize).ceil();
    return _headerLength + plainLength + numChunks * _macLength;
  }

  /// Chiffre [input] par chunks sans jamais le charger entièrement en
  /// mémoire : lit le fichier en streaming, chiffre chaque morceau dès qu'il
  /// est disponible, et émet le résultat au fil de l'eau (utilisable
  /// directement comme corps d'une requête HTTP streamée).
  Stream<List<int>> encryptFileStreaming(
    File input,
    SecretKey mediaKey, {
    int chunkSize = defaultChunkSize,
  }) async* {
    final streamId = Random.secure().nextInt(0xFFFFFFFF);
    yield [..._magic, ..._uint32be(chunkSize), ..._uint32be(streamId)];

    var buffer = <int>[];
    var chunkIndex = 0;
    var emittedAny = false;
    await for (final part in input.openRead()) {
      buffer.addAll(part);
      while (buffer.length >= chunkSize) {
        final chunk = buffer.sublist(0, chunkSize);
        buffer = buffer.sublist(chunkSize);
        yield await _encryptChunk(mediaKey, chunk, streamId, chunkIndex++);
        emittedAny = true;
      }
    }
    if (buffer.isNotEmpty || !emittedAny) {
      yield await _encryptChunk(mediaKey, buffer, streamId, chunkIndex++);
    }
  }

  /// Inverse de [encryptFileStreaming] : consomme le flux chiffré (tel que
  /// téléchargé) et produit le flux en clair, chunk par chunk, sans jamais
  /// retenir le fichier entier en mémoire.
  Stream<List<int>> decryptStreaming(
    Stream<List<int>> encrypted,
    SecretKey mediaKey,
  ) async* {
    var buffer = <int>[];
    int? chunkSize;
    int? streamId;
    var chunkIndex = 0;
    var headerParsed = false;

    await for (final part in encrypted) {
      buffer.addAll(part);
      if (!headerParsed) {
        if (buffer.length < _headerLength) continue;
        if (buffer[0] != _magic[0] ||
            buffer[1] != _magic[1] ||
            buffer[2] != _magic[2] ||
            buffer[3] != _magic[3]) {
          throw const FormatException('Format de blob média invalide (magic)');
        }
        chunkSize = _readUint32be(buffer, 4);
        streamId = _readUint32be(buffer, 8);
        buffer = buffer.sublist(_headerLength);
        headerParsed = true;
      }
      final encChunkLen = chunkSize! + _macLength;
      while (buffer.length >= encChunkLen) {
        final encChunk = buffer.sublist(0, encChunkLen);
        buffer = buffer.sublist(encChunkLen);
        yield await _decryptChunk(mediaKey, encChunk, streamId!, chunkIndex++);
      }
    }
    if (!headerParsed) {
      throw const FormatException('Blob média tronqué (en-tête incomplet)');
    }
    if (buffer.isNotEmpty) {
      yield await _decryptChunk(mediaKey, buffer, streamId!, chunkIndex++);
    }
  }

  Future<List<int>> _encryptChunk(
      SecretKey key, List<int> plain, int streamId, int index) async {
    final nonce = _chunkNonce(streamId, index);
    final box = await AesGcm.with256bits().encrypt(plain, secretKey: key, nonce: nonce);
    return [...box.cipherText, ...box.mac.bytes];
  }

  Future<List<int>> _decryptChunk(
      SecretKey key, List<int> encChunk, int streamId, int index) async {
    final nonce = _chunkNonce(streamId, index);
    final cipherText = encChunk.sublist(0, encChunk.length - _macLength);
    final mac = encChunk.sublist(encChunk.length - _macLength);
    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
    return AesGcm.with256bits().decrypt(box, secretKey: key);
  }

  List<int> _chunkNonce(int streamId, int index) {
    final bytes = Uint8List(nonceLength);
    final bd = ByteData.view(bytes.buffer);
    bd.setUint32(0, streamId, Endian.big);
    bd.setUint32(4, 0, Endian.big);
    bd.setUint32(8, index, Endian.big);
    return bytes;
  }

  List<int> _uint32be(int v) {
    final b = Uint8List(4);
    ByteData.view(b.buffer).setUint32(0, v, Endian.big);
    return b;
  }

  int _readUint32be(List<int> bytes, int offset) {
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  Future<Uint8List> sha256Of(List<int> bytes) async {
    final digest = await Sha256().hash(bytes);
    return Uint8List.fromList(digest.bytes);
  }

  static bool bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
