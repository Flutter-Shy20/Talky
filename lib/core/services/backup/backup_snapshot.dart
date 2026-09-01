import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../db/app_database.dart';
import 'backup_prefs_policy.dart';

/// Nom de la base dans l'archive.
const String kSnapshotDbEntry = 'talky_chat.sqlite';

/// Nom des préférences retenues dans l'archive.
const String kSnapshotPrefsEntry = 'prefs.json';

/// Ce qu'une sauvegarde annonce d'elle-même, **en clair**.
///
/// Publié à côté de l'archive chiffrée sous forme de `latest.json`, il permet
/// à l'écran de réglages d'afficher « dernière sauvegarde : hier, 21 h 04,
/// 8,2 Mo » sans demander la clé au serveur ni déchiffrer quoi que ce soit.
class BackupMeta {
  final DateTime createdAt;
  final int schemaVersion;
  final int messageCount;
  final int conversationCount;

  /// Taille de l'archive scellée. Renseignée après chiffrement, donc nulle
  /// tant que l'instantané n'est pas scellé.
  final int bytes;

  /// Version de clé employée. Sa présence ici, en clair, permet d'annoncer
  /// « version de clé inconnue » avant tout téléchargement.
  final int kid;

  const BackupMeta({
    required this.createdAt,
    required this.schemaVersion,
    required this.messageCount,
    required this.conversationCount,
    this.bytes = 0,
    this.kid = 0,
  });

  BackupMeta copyWith({int? bytes, int? kid}) => BackupMeta(
        createdAt: createdAt,
        schemaVersion: schemaVersion,
        messageCount: messageCount,
        conversationCount: conversationCount,
        bytes: bytes ?? this.bytes,
        kid: kid ?? this.kid,
      );

  Map<String, dynamic> toJson() => {
        'createdAt': createdAt.toUtc().toIso8601String(),
        'schemaVersion': schemaVersion,
        'messageCount': messageCount,
        'conversationCount': conversationCount,
        'bytes': bytes,
        'kid': kid,
      };

  factory BackupMeta.fromJson(Map<String, dynamic> json) => BackupMeta(
        createdAt:
            DateTime.tryParse(json['createdAt']?.toString() ?? '')?.toUtc() ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        schemaVersion: _asInt(json['schemaVersion']) ?? 0,
        messageCount: _asInt(json['messageCount']) ?? 0,
        conversationCount: _asInt(json['conversationCount']) ?? 0,
        bytes: _asInt(json['bytes']) ?? 0,
        kid: _asInt(json['kid']) ?? 0,
      );

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

/// Contenu clair d'une sauvegarde, prêt à être scellé.
class BackupSnapshot {
  /// Archive zip claire : la base plus les préférences retenues.
  final Uint8List payload;
  final BackupMeta meta;

  const BackupSnapshot(this.payload, this.meta);
}

/// Fabrique l'instantané de la base et des préférences.
class BackupSnapshotBuilder {
  final AppDatabase db;

  const BackupSnapshotBuilder(this.db);

  /// Produit le contenu clair d'une sauvegarde.
  ///
  /// [workDir] reçoit la copie temporaire de la base, supprimée avant de
  /// rendre la main.
  Future<BackupSnapshot> build({
    required Directory workDir,
    required Map<String, Object> prefs,
    DateTime? now,
  }) async {
    await workDir.create(recursive: true);
    final temp = File(p.join(
      workDir.path,
      'snapshot_${DateTime.now().microsecondsSinceEpoch}.sqlite',
    ));

    try {
      await _vacuumInto(temp);

      final messages = await _count('local_messages');
      final conversations = await _count('local_conversations');

      final encoder = ZipEncoder();
      final archive = Archive()
        // La base se comprime bien, elle : contrairement aux médias déjà
        // compressés de l'export, deflate y gagne réellement.
        ..addFile(ArchiveFile.bytes(
          kSnapshotDbEntry,
          await temp.readAsBytes(),
        ))
        ..addFile(ArchiveFile.bytes(
          kSnapshotPrefsEntry,
          utf8.encode(jsonEncode(prefs)),
        ));

      return BackupSnapshot(
        Uint8List.fromList(encoder.encode(archive)),
        BackupMeta(
          createdAt: (now ?? DateTime.now()).toUtc(),
          schemaVersion: db.schemaVersion,
          messageCount: messages,
          conversationCount: conversations,
        ),
      );
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  /// Copie cohérente de la base, sans arrêter l'application.
  ///
  /// `VACUUM INTO` est la **seule** manière correcte de faire cela : recopier
  /// le fichier `talky_chat.sqlite` pendant qu'une écriture est en cours
  /// produirait une base corrompue, et le journal d'écriture anticipée rend le
  /// problème invisible jusqu'à la restauration — c'est-à-dire jusqu'au moment
  /// où l'inscrit en a le plus besoin.
  Future<void> _vacuumInto(File destination) async {
    // Le chemin ne peut pas être un paramètre lié dans un `VACUUM` : il est
    // donc interpolé, avec doublement des apostrophes. Il vient d'un dossier
    // temporaire que nous choisissons, jamais d'une entrée extérieure.
    final escaped = destination.path.replaceAll("'", "''");
    await db.customStatement("VACUUM INTO '$escaped'");
  }

  Future<int> _count(String table) async {
    final rows = await db.customSelect('SELECT COUNT(*) AS n FROM $table').get();
    return rows.isEmpty ? 0 : (rows.first.data['n'] as int? ?? 0);
  }
}

/// Relit le contenu clair d'une sauvegarde déchiffrée.
class BackupSnapshotReader {
  /// Version de schéma que cette application sait ouvrir.
  final int supportedSchemaVersion;

  const BackupSnapshotReader(this.supportedSchemaVersion);

  /// Extrait la base et les préférences.
  ///
  /// [declaredSchemaVersion] vient de l'en-tête en clair de l'archive, donc
  /// connu avant même le déchiffrement.
  BackupSnapshotContent read(
    Uint8List payload, {
    required int declaredSchemaVersion,
  }) {
    if (declaredSchemaVersion > supportedSchemaVersion) {
      // Ouvrir une base au schéma futur, c'est la corrompre. Les migrations
      // Drift savent avancer, jamais reculer.
      throw BackupSchemaTooRecent(
        declaredSchemaVersion,
        supportedSchemaVersion,
      );
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(payload);
    } catch (_) {
      throw const BackupSnapshotUnreadable('contenu illisible');
    }

    final dbEntry =
        archive.files.where((f) => f.name == kSnapshotDbEntry).firstOrNull;
    if (dbEntry == null) {
      throw const BackupSnapshotUnreadable('base absente de la sauvegarde');
    }

    final prefsEntry =
        archive.files.where((f) => f.name == kSnapshotPrefsEntry).firstOrNull;
    var prefs = <String, Object>{};
    if (prefsEntry != null) {
      try {
        final decoded = jsonDecode(utf8.decode(prefsEntry.readBytes()!));
        if (decoded is Map<String, dynamic>) {
          // La liste blanche s'applique aussi à la LECTURE : une archive
          // fabriquée à la main ne doit pas pouvoir injecter n'importe quoi
          // dans les préférences de l'appareil.
          prefs = filterRestorablePrefs(decoded);
        }
      } catch (_) {
        // Des préférences illisibles ne doivent pas coûter les messages :
        // on restaure la base et on repart des réglages par défaut.
        prefs = <String, Object>{};
      }
    }

    return BackupSnapshotContent(
      database: Uint8List.fromList(dbEntry.readBytes()!),
      prefs: prefs,
    );
  }
}

/// Contenu extrait d'une sauvegarde.
class BackupSnapshotContent {
  final Uint8List database;
  final Map<String, Object> prefs;

  const BackupSnapshotContent({required this.database, required this.prefs});
}

/// La sauvegarde vient d'une version plus récente de l'application.
class BackupSchemaTooRecent implements Exception {
  final int found;
  final int supported;
  const BackupSchemaTooRecent(this.found, this.supported);

  @override
  String toString() =>
      'BackupSchemaTooRecent(found: $found, supported: $supported)';
}

/// Le contenu déchiffré n'est pas une sauvegarde exploitable.
class BackupSnapshotUnreadable implements Exception {
  final String reason;
  const BackupSnapshotUnreadable(this.reason);

  @override
  String toString() => 'BackupSnapshotUnreadable($reason)';
}

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '');
}
