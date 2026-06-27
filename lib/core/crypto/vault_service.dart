// F3 — Coffre d'historique (vault)
//
// Chiffrement de second niveau : avant chaque envoi le plaintext est chiffré
// avec une clé dérivée du mot de passe de l'utilisateur (PBKDF2-SHA256,
// 200 000 itérations). La clé ne quitte jamais l'appareil.
//
// Usage :
//   1. À la connexion : vault.unlock(userId, password, saltBytes)
//   2. Sur redémarrage : vault.tryLoad(userId) — restaure depuis secure storage.
//   3. Avant envoi   : vault.seal(plaintext) → (blob, nonce) inclus dans le message.
//   4. Réception / historique propre : vault.open(blob, nonce) → plaintext.
//   5. Déconnexion   : vault.lock()
//
// Note production : remplacer PBKDF2 par Argon2id (package argon2_ffi).

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class VaultService {
  static const _storePrefix = 'talky_vault_v1_';

  // PBKDF2 : 200 000 itérations, SHA-256, sortie 32 octets.
  // À remplacer par Argon2id (params mémoire+temps) en production.
  static const _pbkdf2Iterations = 200000;

  final FlutterSecureStorage _secure;
  SecretKey? _key;

  VaultService() : _secure = const FlutterSecureStorage();

  bool get isUnlocked => _key != null;

  // ── Déverrouillage ────────────────────────────────────────────────────────

  /// Dérive la clé de coffre depuis [password] et [salt] (16+ octets du serveur).
  /// Stocke la clé dérivée dans secure storage pour les redémarrages.
  Future<void> unlock(int userId, String password, List<int> salt) async {
    _key = await _derive(password, salt);
    final keyBytes = await _key!.extractBytes();
    await _secure.write(
      key: '$_storePrefix$userId',
      value: base64Encode(keyBytes),
    );
    debugPrint('[Vault] coffre ouvert (userId=$userId)');
  }

  /// Tente de restaurer la clé depuis le secure storage (redémarrage sans saisie mdp).
  /// Retourne true si la clé a été chargée.
  Future<bool> tryLoad(int userId) async {
    final stored = await _secure.read(key: '$_storePrefix$userId');
    if (stored == null) return false;
    _key = SecretKey(base64Decode(stored));
    debugPrint('[Vault] clé chargée depuis storage (userId=$userId)');
    return true;
  }

  // ── Chiffrement / déchiffrement ───────────────────────────────────────────

  /// Chiffre [plaintext] avec la clé de coffre.
  /// Retourne `null` si le coffre est verrouillé.
  Future<({String blob, String nonce})?> seal(String plaintext) async {
    if (_key == null) return null;
    try {
      final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode(plaintext),
        secretKey: _key!,
        nonce: nonce,
      );
      final payload = [...box.cipherText, ...box.mac.bytes];
      return (
        blob: base64Encode(payload),
        nonce: base64Encode(nonce),
      );
    } catch (e) {
      debugPrint('[Vault] seal échoué: $e');
      return null;
    }
  }

  /// Déchiffre un [blobB64] produit par [seal].
  /// Retourne `null` si le coffre est verrouillé ou si le déchiffrement échoue.
  Future<String?> open(String blobB64, String nonceB64) async {
    if (_key == null) return null;
    try {
      const macLen = 16;
      final payload = base64Decode(blobB64);
      final box = SecretBox(
        payload.sublist(0, payload.length - macLen),
        nonce: base64Decode(nonceB64),
        mac: Mac(payload.sublist(payload.length - macLen)),
      );
      final plain = await AesGcm.with256bits().decrypt(box, secretKey: _key!);
      return utf8.decode(plain);
    } catch (e) {
      debugPrint('[Vault] open échoué: $e');
      return null;
    }
  }

  // ── Fermeture ─────────────────────────────────────────────────────────────

  /// Vide la clé de la mémoire (logout ou minimisation). La clé reste dans
  /// le secure storage et sera rechargée par [tryLoad] au prochain bind().
  void lock() {
    _key = null;
  }

  // ── KDF ───────────────────────────────────────────────────────────────────

  Future<SecretKey> _derive(String password, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _pbkdf2Iterations,
      bits: 256, // 32 octets
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }
}
