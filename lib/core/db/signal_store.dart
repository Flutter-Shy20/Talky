// signal_store.dart — Persistance des sessions Double Ratchet et des OTPKs
//
// Classe plain Dart (pas de @DriftAccessor) qui opère directement sur les
// tables E2eeSessions et E2eeOtpks définies dans AppDatabase.
// Les noms e2eeSessions / e2eeOtpks sont générés par build_runner.

import 'dart:typed_data';

import 'package:drift/drift.dart';

import 'app_database.dart';

class SignalStore {
  final AppDatabase _db;

  SignalStore(this._db);

  // ── Sessions ──────────────────────────────────────────────────────────────

  /// Charge l'état d'une session DR pour la paire (owner, peer).
  Future<E2eeSession?> loadSession(int owner, int peer) =>
      (_db.select(_db.e2eeSessions)
            ..where((r) =>
                r.ownerUserId.equals(owner) & r.peerId.equals(peer)))
          .getSingleOrNull();

  /// Insère ou remplace l'état d'une session.
  Future<void> storeSession(E2eeSessionsCompanion c) =>
      _db.into(_db.e2eeSessions).insertOnConflictUpdate(c);

  /// Supprime la session d'une paire.
  Future<void> deleteSession(int owner, int peer) =>
      (_db.delete(_db.e2eeSessions)
            ..where((r) =>
                r.ownerUserId.equals(owner) & r.peerId.equals(peer)))
          .go();

  // ── One-time prekeys ──────────────────────────────────────────────────────

  /// Toutes les OTPKs non consommées pour cet owner.
  Future<List<E2eeOtpk>> loadAllOtpks(int owner) =>
      (_db.select(_db.e2eeOtpks)
            ..where((r) => r.ownerUserId.equals(owner)))
          .get();

  /// Insère ou remplace une OTPK.
  Future<void> storeOtpk(int owner, int otpkId, Uint8List privBytes) =>
      _db.into(_db.e2eeOtpks).insertOnConflictUpdate(E2eeOtpksCompanion(
        ownerUserId: Value(owner),
        otpkId: Value(otpkId),
        privBytes: Value(privBytes),
      ));

  /// Supprime une OTPK consommée (one-time = usage unique).
  Future<void> deleteOtpk(int owner, int otpkId) =>
      (_db.delete(_db.e2eeOtpks)
            ..where((r) =>
                r.ownerUserId.equals(owner) & r.otpkId.equals(otpkId)))
          .go();

  /// Supprime toutes les OTPKs d'un owner (avant re-upload d'un nouveau lot).
  Future<void> clearOtpks(int owner) =>
      (_db.delete(_db.e2eeOtpks)
            ..where((r) => r.ownerUserId.equals(owner)))
          .go();
}
