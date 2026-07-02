// sender_key_store.dart — Persistance des Sender Keys (E2EE groupe)
//
// Classe plain Dart (pas de @DriftAccessor) qui opère directement sur la
// table SenderKeyRows définie dans AppDatabase, dans le même style que
// SignalStore (sessions Double Ratchet 1-à-1).
//
// `DriftSenderKeyStore` implémente l'interface `SenderKeyStore` attendue par
// `libsignal_protocol_dart` (GroupSessionBuilder / GroupCipher) : le contenu
// du `SenderKeyRecord` (chaîne, itération, clé de signature) est entièrement
// géré par la lib, le store n'a besoin que de persister ses octets sérialisés.

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'app_database.dart';

class SenderKeyDao {
  final AppDatabase _db;

  SenderKeyDao(this._db);

  Future<Uint8List?> loadRecordBytes(int owner, int groupId, int senderId) async {
    final row = await (_db.select(_db.senderKeyRows)
          ..where((r) =>
              r.ownerUserId.equals(owner) &
              r.groupId.equals(groupId) &
              r.senderId.equals(senderId)))
        .getSingleOrNull();
    return row?.recordBytes;
  }

  Future<void> storeRecordBytes(
      int owner, int groupId, int senderId, Uint8List bytes) =>
      _db.into(_db.senderKeyRows).insertOnConflictUpdate(SenderKeyRowsCompanion(
            ownerUserId: Value(owner),
            groupId: Value(groupId),
            senderId: Value(senderId),
            recordBytes: Value(bytes),
          ));

  /// Toutes les lignes connues pour un groupe (utile pour compter les membres
  /// dont on détient déjà une sender key, débogage/vérification).
  Future<List<SenderKeyRow>> loadAllForGroup(int owner, int groupId) =>
      (_db.select(_db.senderKeyRows)
            ..where((r) =>
                r.ownerUserId.equals(owner) & r.groupId.equals(groupId)))
          .get();

  /// `userId` à qui MA clé d'émission courante (senderId == owner) a déjà
  /// été distribuée pour ce groupe.
  Future<Set<int>> loadDistributedTo(int owner, int groupId) async {
    final row = await (_db.select(_db.senderKeyRows)
          ..where((r) =>
              r.ownerUserId.equals(owner) &
              r.groupId.equals(groupId) &
              r.senderId.equals(owner)))
        .getSingleOrNull();
    if (row == null) return {};
    final list = jsonDecode(row.distributedToJson) as List;
    return list.map((e) => e as int).toSet();
  }

  Future<void> markDistributedTo(int owner, int groupId, Set<int> targetIds) async {
    await (_db.update(_db.senderKeyRows)
          ..where((r) =>
              r.ownerUserId.equals(owner) &
              r.groupId.equals(groupId) &
              r.senderId.equals(owner)))
        .write(SenderKeyRowsCompanion(
          distributedToJson: Value(jsonEncode(targetIds.toList())),
        ));
  }
}

/// Adapte `SenderKeyDao` (Drift) à l'interface `SenderKeyStore` attendue par
/// `GroupSessionBuilder`/`GroupCipher`. Une instance par utilisateur courant
/// (`ownerUserId` fixé à la construction), comme `E2eeService`.
class DriftSenderKeyStore implements SenderKeyStore {
  DriftSenderKeyStore(this._dao, this._ownerUserId);

  final SenderKeyDao _dao;
  final int _ownerUserId;

  int _senderIdOf(SenderKeyName name) => int.parse(name.sender.getName());

  @override
  Future<void> storeSenderKey(
      SenderKeyName senderKeyName, SenderKeyRecord record) async {
    await _dao.storeRecordBytes(
      _ownerUserId,
      int.parse(senderKeyName.groupId),
      _senderIdOf(senderKeyName),
      record.serialize(),
    );
  }

  @override
  Future<SenderKeyRecord> loadSenderKey(SenderKeyName senderKeyName) async {
    final bytes = await _dao.loadRecordBytes(
      _ownerUserId,
      int.parse(senderKeyName.groupId),
      _senderIdOf(senderKeyName),
    );
    return bytes != null
        ? SenderKeyRecord.fromSerialized(bytes)
        : SenderKeyRecord();
  }
}
