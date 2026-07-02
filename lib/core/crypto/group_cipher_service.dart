// group_cipher_service.dart — Chiffrement E2EE des groupes (Sender Keys)
//
// Couche fine au-dessus de `libsignal_protocol_dart` (GroupSessionBuilder /
// GroupCipher). Le 1-à-1 (E2eeService, Double Ratchet maison) reste
// responsable du transport chiffré des messages de distribution de sender
// key : cette classe ne fait ni X3DH ni Double Ratchet, uniquement le
// chiffrement/déchiffrement des messages de GROUPE une fois la sender key du
// membre concerné connue.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../talky_api_client.dart';
import '../db/app_database.dart';
import '../db/sender_key_store.dart';
import 'e2ee_service.dart';

/// Résultat d'un chiffrement de groupe, prêt à diffuser via `message:send`.
class GroupEncryptResult {
  final String ciphertext; // base64
  const GroupEncryptResult(this.ciphertext);

  Map<String, dynamic> toSocketMap() => {'ciphertext': ciphertext};
}

class GroupCipherService {
  final TalkyApiClient _api;
  final E2eeService _e2ee;
  final SenderKeyDao _dao;

  int _myId = 0;
  DriftSenderKeyStore? _store;

  GroupCipherService(this._api, this._e2ee, {AppDatabase? db})
      : _dao = SenderKeyDao(db ?? AppDatabase());

  void init(int userId) {
    _myId = userId;
    _store = DriftSenderKeyStore(_dao, userId);
  }

  SignalProtocolAddress _addr(int userId) =>
      SignalProtocolAddress(userId.toString(), 1);

  SenderKeyName _myName(int groupId) =>
      SenderKeyName(groupId.toString(), _addr(_myId));

  SenderKeyName _theirName(int groupId, int senderId) =>
      SenderKeyName(groupId.toString(), _addr(senderId));

  // ── Création + distribution ────────────────────────────────────────────

  /// Génère (si besoin — idempotent) ma sender key pour ce groupe et la
  /// distribue, via le canal 1-à-1 existant, à tout membre pas déjà notifié
  /// pour l'epoch courante. Symétrique : appelable aussi bien par le membre
  /// qui vient de rejoindre que par les membres déjà présents.
  Future<void> createOrDistribute(int groupId, List<int> memberIds) async {
    if (_store == null) return;
    try {
      final builder = GroupSessionBuilder(_store!);
      final skdm = await builder.create(_myName(groupId));
      final payloadB64 = base64Encode(skdm.serialize());

      final already = await _dao.loadDistributedTo(_myId, groupId);
      final targets = memberIds.where((id) => id != _myId && !already.contains(id));

      final newlyDistributed = <int>{};
      for (final targetId in targets) {
        final sealed = await _e2ee.encrypt(targetId, payloadB64);
        if (sealed == null) continue; // pas de bundle/session dispo — retentera plus tard
        _api.sendSocketEvent('group:key_distribution', {
          'targetUserId': targetId,
          'groupId': groupId,
          'encryptedPayload': sealed.toSocketMap(),
        });
        newlyDistributed.add(targetId);
      }
      if (newlyDistributed.isNotEmpty) {
        await _dao.markDistributedTo(_myId, groupId, {...already, ...newlyDistributed});
      }
    } catch (e) {
      debugPrint('[GroupE2EE] createOrDistribute($groupId) échoué: $e');
    }
  }

  /// Régénère une nouvelle epoch (nouvelle chaîne) et la redistribue aux
  /// membres restants. À appeler uniquement sur `group:member_removed` (un
  /// membre a quitté) — jamais sur une décision locale.
  Future<void> rotate(int groupId, List<int> remainingMemberIds) async {
    if (_store == null) return;
    // Repartir d'une ligne vide force `GroupSessionBuilder.create` à générer
    // une nouvelle chaîne (il ne régénère que si `senderKeyRecord.isEmpty`).
    await _dao.storeRecordBytes(_myId, groupId, _myId, SenderKeyRecord().serialize());
    await _dao.markDistributedTo(_myId, groupId, {});
    await createOrDistribute(groupId, remainingMemberIds);
  }

  /// Traite un message de distribution reçu (déjà déchiffré via le 1-à-1).
  Future<void> processDistribution(
      int fromUserId, int groupId, String payloadB64) async {
    if (_store == null) return;
    try {
      final builder = GroupSessionBuilder(_store!);
      final wrapper =
          SenderKeyDistributionMessageWrapper.fromSerialized(base64Decode(payloadB64));
      await builder.process(_theirName(groupId, fromUserId), wrapper);
    } catch (e) {
      debugPrint('[GroupE2EE] processDistribution($groupId, $fromUserId) échoué: $e');
    }
  }

  // ── Chiffrement / déchiffrement des messages ───────────────────────────

  Future<GroupEncryptResult?> encrypt(int groupId, String plaintext) async {
    if (_store == null) return null;
    try {
      final cipher = GroupCipher(_store!, _myName(groupId));
      final ct = await cipher.encrypt(Uint8List.fromList(utf8.encode(plaintext)));
      return GroupEncryptResult(base64Encode(ct));
    } catch (e) {
      debugPrint('[GroupE2EE] encrypt($groupId) échoué: $e');
      return null;
    }
  }

  /// `null` si la sender key de `fromUserId` n'est pas encore connue (la
  /// distribution n'est pas encore arrivée) — le message reste affiché avec
  /// le fallback générique existant, pas de file d'attente en v1.
  Future<String?> decrypt(int groupId, int fromUserId, String ciphertextB64) async {
    if (_store == null) return null;
    try {
      final cipher = GroupCipher(_store!, _theirName(groupId, fromUserId));
      final pt = await cipher.decrypt(base64Decode(ciphertextB64));
      return utf8.decode(pt);
    } catch (e) {
      debugPrint('[GroupE2EE] decrypt($groupId, $fromUserId) échoué: $e');
      return null;
    }
  }
}
