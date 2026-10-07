import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talky_flutter/core/db/app_database.dart';
import 'package:talky_flutter/core/services/backup/backup_runner.dart';
import 'package:talky_flutter/core/services/backup/backup_service.dart';
import 'package:talky_flutter/core/services/backup/backup_target.dart';
import 'package:talky_flutter/core/services/backup/local_folder_target.dart';
import 'package:talky_flutter/core/services/backup/restore_state.dart';
import 'package:talky_flutter/core/services/connectivity_service.dart';

/// La restauration ne se propose qu'une fois par installation.
///
/// Restée ouverte, la question se reposait à chaque démarrage : la première
/// sauvegarde faite par un téléphone lui était proposée au démarrage suivant,
/// comme si elle venait d'un autre.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const store = RestoreStateStore();

  Future<void> startAt(RestoreStage stage) async =>
      SharedPreferences.setMockInitialValues({'restore_stage': stage.name});

  group('question close', () {
    for (final open in [RestoreStage.unknown, RestoreStage.offered]) {
      test('rien à restaurer : ${open.name} → close', () async {
        await startAt(open);
        await store.markNotNeeded();
        expect(await store.stage(), RestoreStage.notNeeded);
        expect(await store.shouldOffer(), isFalse);
      });
    }

    for (final kept in [
      RestoreStage.skipped,
      RestoreStage.done,
      RestoreStage.pendingSwap,
      RestoreStage.inProgress,
    ]) {
      test('${kept.name} n\'est jamais écrasé', () async {
        await startAt(kept);
        await store.markNotNeeded();
        expect(await store.stage(), kept);
      });
    }
  });

  group('réouverture après effacement des données locales', () {
    for (final settled in [
      RestoreStage.notNeeded,
      RestoreStage.skipped,
      RestoreStage.done,
    ]) {
      test('${settled.name} → la question se repose', () async {
        await startAt(settled);
        await store.reopenAfterWipe();
        expect(await store.shouldOffer(), isTrue);
      });
    }

    for (final busy in [RestoreStage.pendingSwap, RestoreStage.inProgress]) {
      test('${busy.name} : laissé au démarrage', () async {
        await startAt(busy);
        await store.reopenAfterWipe();
        expect(await store.stage(), busy);
      });
    }
  });

  group('sauvegarde faite par ce téléphone', () {
    late AppDatabase db;
    late Directory tmp;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      tmp = await Directory.systemTemp.createTemp('alanya_restore_once');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => tmp.path,
      );
    });

    tearDown(() async {
      BackupRunner.releaseLockForTest();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      await db.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<BackupRunResult> backUp(BackupTarget target) async {
      final attempt = await BackupRunner(
        db: db,
        keys: _FakeKeys(),
        connectivity: ConnectivityService(),
        target: target,
      ).runNow(alanyaID: 15, now: DateTime.utc(2026, 10, 1, 6, 49));
      return attempt.result;
    }

    LocalFolderTarget device() =>
        LocalFolderTarget(Directory(p.join(tmp.path, 'Alanya')));

    test('réussie : la question est close', () async {
      await startAt(RestoreStage.unknown);
      expect(await backUp(device()), BackupRunResult.success);
      expect(await store.stage(), RestoreStage.notNeeded);
    });

    test('échouée : la question reste ouverte', () async {
      await startAt(RestoreStage.unknown);
      expect(await backUp(_BrokenTarget()), BackupRunResult.failure);
      expect(await store.stage(), RestoreStage.unknown);
    });

    test('une restauration en attente n\'est pas effacée', () async {
      await startAt(RestoreStage.pendingSwap);
      expect(await backUp(device()), BackupRunResult.success);
      expect(await store.stage(), RestoreStage.pendingSwap);
    });
  });
}

class _FakeKeys implements BackupKeyProvider {
  @override
  Future<BackupKey> current() async => BackupKey(1, List<int>.filled(32, 1));

  @override
  Future<BackupKey> byKid(int kid) => current();
}

/// Destination qui refuse tout dépôt.
class _BrokenTarget implements BackupTarget {
  @override
  String get label => 'en panne';

  @override
  Future<List<RemoteArchive>> list() async => const [];

  @override
  Future<RemoteArchive> write(File local, String name) =>
      throw const FileSystemException('disque plein');

  @override
  Future<File> read(String id, File into) => throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();
}
