import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:talky_flutter/core/db/app_database.dart';
import 'package:talky_flutter/core/services/backup/backup_runner.dart';
import 'package:talky_flutter/core/services/backup/backup_service.dart';
import 'package:talky_flutter/core/services/backup/backup_snapshot.dart';
import 'package:talky_flutter/core/services/backup/backup_target.dart';
import 'package:talky_flutter/core/services/backup/drive_backup_target.dart';
import 'package:talky_flutter/core/services/backup/local_folder_target.dart';
import 'package:talky_flutter/core/theme/app_theme.dart';
import 'package:talky_flutter/l10n/app_localizations.dart';
import 'package:talky_flutter/screens/profile/restore_screen.dart';

/// Sur un téléphone neuf, le choix « Drive » n'est pas encore restauré : il
/// est dans la sauvegarde. L'écran de restauration doit donc apprendre du
/// serveur où chercher, sinon son bouton principal fouille un appareil vide.
void main() {
  final l10n = lookupAppLocalizations(const Locale('fr'));

  group('déclaration au serveur', () {
    final meta = BackupMeta(
      createdAt: DateTime.utc(2026, 10, 1, 6, 49),
      schemaVersion: 1,
      messageCount: 120,
      conversationCount: 4,
      bytes: 2800000,
      kid: 1,
    );

    final driveTarget = DriveBackupTarget(
      drive.DriveApi(MockClient((_) async => http.Response('', 500))),
      accountEmail: 'amina@gmail.com',
    );
    final deviceTarget = LocalFolderTarget(Directory.systemTemp);

    Future<(bool, String?)> declare(
      BackupTarget target, {
      bool isFallback = false,
    }) async {
      var called = false;
      String? account;
      final announce = BackupRunner.announcerFor(
        (m, driveAccount) async {
          called = true;
          account = driveAccount;
        },
        target,
        isFallback: isFallback,
      );
      await announce?.call(meta);
      return (called, account);
    }

    test('dépôt sur Drive : l\'adresse du compte Google est transmise',
        () async {
      expect(await declare(driveTarget), (true, 'amina@gmail.com'));
    });

    test('dépôt sur le téléphone : déclaré, sans adresse', () async {
      expect(await declare(deviceTarget), (true, null));
    });

    test('repli sur le téléphone : rien n\'est déclaré', () async {
      // Le serveur doit continuer d'annoncer la dernière sauvegarde Drive, la
      // seule qu'un téléphone neuf pourra lire.
      expect(await declare(deviceTarget, isFallback: true), (false, null));
    });

    test('sans rappel : rien à déclarer', () {
      expect(
        BackupRunner.announcerFor(null, driveTarget, isFallback: false),
        isNull,
      );
    });
  });

  group('écran de restauration', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<void> pumpScreen(WidgetTester tester, {String? accountHint}) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('fr'),
        home: RestoreScreen(
          db: db,
          keys: _NoKeys(),
          target: _EmptyDevice(),
          announcement: BackupAnnouncement(
            lastAt: DateTime.utc(2026, 10, 1, 6, 49),
            bytes: 2800000,
            accountHint: accountHint,
          ),
          onSkip: () {},
          alanyaID: 15,
        ),
      ));
    }

    testWidgets('sauvegarde sur Drive : Drive en bouton principal',
        (tester) async {
      await pumpScreen(tester, accountHint: 'a•••@gmail.com');

      expect(find.text(l10n.restoreFromDrive), findsOneWidget);
      expect(find.text(l10n.restoreDriveAccount('a•••@gmail.com')),
          findsOneWidget);
      // Chercher sur l'appareil ne trouverait rien : le bouton n'est pas offert.
      expect(find.text(l10n.restoreAction), findsNothing);
      expect(find.text(l10n.restoreConnectGoogle), findsNothing);
      expect(find.text(l10n.restorePickFile), findsOneWidget);
      expect(find.text(l10n.restoreSkip), findsOneWidget);
    });

    testWidgets('emplacement inconnu : appareil d\'abord, Drive proposé',
        (tester) async {
      await pumpScreen(tester);

      expect(find.text(l10n.restoreAction), findsOneWidget);
      expect(find.text(l10n.restoreConnectGoogle), findsOneWidget);
      expect(find.text(l10n.restoreFromDrive), findsNothing);
    });

    testWidgets('appareil vide : message précis, puis Drive en tête',
        (tester) async {
      await pumpScreen(tester);

      await tester.tap(find.text(l10n.restoreAction));
      await tester.pump();
      await tester.pump();

      expect(find.text(l10n.restoreNothingOnDevice), findsOneWidget);
      expect(find.text(l10n.restoreFailedMessage), findsNothing);
      expect(find.text(l10n.restoreFromDrive), findsOneWidget);
      expect(find.text(l10n.restoreAction), findsNothing);
    });
  });
}

/// L'appareil d'un téléphone neuf : rien à lister.
class _EmptyDevice implements BackupTarget {
  @override
  String get label => 'Stockage de l\'appareil';

  @override
  Future<List<RemoteArchive>> list() async => const [];

  @override
  Future<RemoteArchive> write(File local, String name) =>
      throw UnimplementedError();

  @override
  Future<File> read(String id, File into) => throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();
}

class _NoKeys implements BackupKeyProvider {
  @override
  Future<BackupKey> current() => throw UnimplementedError();

  @override
  Future<BackupKey> byKid(int kid) => throw UnimplementedError();
}
