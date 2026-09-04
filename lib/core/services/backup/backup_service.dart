import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../db/app_database.dart';
import 'backup_crypto.dart';
import 'backup_snapshot.dart';
import 'backup_target.dart';

/// Une clé de sauvegarde et son numéro de version.
class BackupKey {
  final int kid;
  final List<int> bytes;

  const BackupKey(this.kid, this.bytes);
}

/// Fournit les clés de chiffrement des sauvegardes.
///
/// Deux méthodes et non une : écrire demande la version courante, relire
/// demande **la version qui a servi**, lue dans l'en-tête en clair de
/// l'archive. C'est ce qui permet de remplacer un secret serveur sans rendre
/// illisibles les sauvegardes déjà déposées.
///
/// La clé n'est jamais écrite en clair sur le téléphone : on la demande, on
/// s'en sert, on l'oublie.
abstract class BackupKeyProvider {
  /// Version courante, pour écrire une nouvelle sauvegarde.
  Future<BackupKey> current();

  /// Version [kid], pour relire une archive ancienne. Lève si le serveur ne
  /// connaît pas ce numéro — cas à annoncer tel quel à l'inscrit.
  Future<BackupKey> byKid(int kid);
}

/// Résultat d'une tentative de sauvegarde.
class BackupOutcome {
  final bool succeeded;
  final RemoteArchive? archive;
  final BackupMeta? meta;
  final Object? error;

  const BackupOutcome.success(this.archive, this.meta)
      : succeeded = true,
        error = null;

  const BackupOutcome.failure(this.error)
      : succeeded = false,
        archive = null,
        meta = null;
}

/// Fabrique, chiffre et dépose une sauvegarde ; entretient l'historique.
class BackupService {
  /// Nombre d'archives conservées à la destination.
  ///
  /// **Deux, jamais une.** La nouvelle n'écrase l'ancienne qu'une fois écrite
  /// et relue. Le coût est dérisoire — la base pèse quelques mégaoctets — et
  /// il ferme le seul scénario qui rend une sauvegarde inutile : une écriture
  /// interrompue qui détruit la dernière copie valable.
  static const int keptVersions = 2;

  final AppDatabase db;
  final BackupKeyProvider keys;
  final BackupCrypto crypto;

  BackupService({
    required this.db,
    required this.keys,
    BackupCrypto? crypto,
  }) : crypto = crypto ?? BackupCrypto();

  Future<BackupOutcome> run({
    required BackupTarget target,
    required int alanyaID,
    required Map<String, Object> prefs,
    required Directory workDir,
    DateTime? now,
    /// Appelé après vérification, pour déclarer la sauvegarde au serveur.
    ///
    /// Un crochet plutôt qu'un appel direct : le service reste ignorant de
    /// l'API, donc éprouvable sans réseau. Et un échec ici **n'invalide pas**
    /// la sauvegarde — elle est écrite et vérifiée, seule la métadonnée
    /// manque. La prochaine réussie la reposera.
    Future<void> Function(BackupMeta meta)? onSucceeded,
  }) async {
    File? staged;
    try {
      final key = await keys.current();
      final snapshot = await BackupSnapshotBuilder(db).build(
        workDir: workDir,
        prefs: prefs,
        now: now,
      );

      final sealed = await crypto.seal(
        plain: snapshot.payload,
        key: key.bytes,
        kid: key.kid,
        alanyaID: alanyaID,
        schemaVersion: snapshot.meta.schemaVersion,
      );

      final name = archiveName(alanyaID, snapshot.meta.createdAt);
      staged = File(p.join(workDir.path, name));
      await staged.writeAsBytes(sealed, flush: true);

      final archive = await target.write(staged, name);
      await _verify(target, archive, sealed.length);

      final meta = snapshot.meta.copyWith(
        bytes: sealed.length,
        kid: key.kid,
      );
      await _publishMeta(target, alanyaID, meta);

      // Seulement maintenant : la nouvelle archive est écrite ET relue.
      await _prune(target, alanyaID, keep: archive.name);

      if (onSucceeded != null) {
        try {
          await onSucceeded(meta);
        } catch (e) {
          // Réseau coupé au mauvais moment : la sauvegarde est bel et bien
          // déposée, ne pas la déclarer perdue pour autant. Le seul effet est
          // que l'écran de restauration ne la connaîtra pas encore.
          //
          // Mais l'avaler en silence rend le défaut indiagnosticable : une
          // sauvegarde réussie que le serveur ignore ressemble, côté inscrit,
          // à une sauvegarde qui n'existe pas. La trace est le seul moyen de
          // distinguer les deux.
          debugPrint('[Backup] ** déclaration au serveur échouée: $e');
        }
      }

      return BackupOutcome.success(archive, meta);
    } catch (e) {
      return BackupOutcome.failure(e);
    } finally {
      // Le fichier de travail contient la sauvegarde chiffrée : inutile de le
      // garder une fois déposé, et il pèse le poids d'une base entière.
      if (staged != null && await staged.exists()) {
        await staged.delete();
      }
    }
  }

  /// Relit ce qui vient d'être écrit avant de toucher à l'existant.
  ///
  /// Sans cette vérification, un dépôt partiel — réseau coupé en fin de
  /// téléversement, quota atteint — serait pris pour un succès, et la purge
  /// détruirait ensuite la dernière sauvegarde valable.
  Future<void> _verify(
    BackupTarget target,
    RemoteArchive written,
    int expectedBytes,
  ) async {
    final listed = await target.list();
    final found = listed.where((a) => a.id == written.id).firstOrNull;
    if (found == null) {
      throw const BackupVerificationFailed('archive introuvable après dépôt');
    }
    if (found.bytes != expectedBytes) {
      throw BackupVerificationFailed(
        'taille inattendue : ${found.bytes} au lieu de $expectedBytes',
      );
    }
  }

  /// Publie le descriptif **en clair** à côté de l'archive.
  ///
  /// Il porte la date, la taille, le nombre de messages et le `kid`. L'écran
  /// de réglages peut ainsi afficher « dernière sauvegarde : hier, 21 h 04,
  /// 8,2 Mo » sans demander la clé au serveur, et l'écran de restauration peut
  /// annoncer « version de clé inconnue » avant de télécharger quoi que ce
  /// soit.
  Future<void> _publishMeta(
    BackupTarget target,
    int alanyaID,
    BackupMeta meta,
  ) async {
    final dir = await Directory.systemTemp.createTemp('alanya_meta');
    try {
      final file = File(p.join(dir.path, metaName(alanyaID)));
      await file.writeAsString(meta.encode(), flush: true);
      await target.write(file, metaName(alanyaID));
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  /// Ne garde que les [keptVersions] archives les plus récentes de ce compte.
  ///
  /// Le descriptif en clair et les archives d'autres comptes ne sont jamais
  /// touchés : un même téléphone peut porter deux comptes Alanya, et effacer
  /// la sauvegarde de l'autre serait un dégât irréparable.
  Future<void> _prune(
    BackupTarget target,
    int alanyaID, {
    required String keep,
  }) async {
    final prefix = 'alanya-backup-$alanyaID-';
    final mine = (await target.list())
        .where((a) => a.name.startsWith(prefix) && a.name.endsWith('.enc'))
        .toList()
      // Les noms portent un horodatage compact : l'ordre lexical est l'ordre
      // chronologique, sans dépendre de l'heure de modification que certaines
      // destinations réécrivent au dépôt.
      ..sort((a, b) => b.name.compareTo(a.name));

    for (var i = keptVersions; i < mine.length; i++) {
      if (mine[i].name == keep) continue;
      await target.delete(mine[i].id);
    }
  }

  /// Relit une sauvegarde déposée : en-tête, clé de la bonne version, contenu.
  Future<BackupSnapshotContent> restore({
    required BackupTarget target,
    required RemoteArchive archive,
    required Directory workDir,
  }) async {
    await workDir.create(recursive: true);
    final local = File(p.join(workDir.path, archive.name));
    await target.read(archive.id, local);

    final bytes = await local.readAsBytes();
    // L'en-tête est lu AVANT de demander la clé : c'est lui qui dit laquelle.
    final header = BackupHeader.decode(bytes);
    if (!header.isSupported) {
      throw const BackupFormatInvalid('version de format non prise en charge');
    }

    final key = await keys.byKid(header.kid);
    final clear = await crypto.open(archive: bytes, key: key.bytes);

    return BackupSnapshotReader(db.schemaVersion).read(
      Uint8List.fromList(clear),
      declaredSchemaVersion: header.schemaVersion,
    );
  }

  /// Restaure la **plus récente archive lisible** parmi [candidates].
  ///
  /// ── Pourquoi une boucle et non la première ──
  ///
  /// [keptVersions] vaut deux, et ce n'est pas décoratif : la seconde existe
  /// pour le jour où la première est illisible. Le code ne prenait pourtant
  /// que `archives.first` et abandonnait sur échec — on conservait donc
  /// scrupuleusement un filet dans lequel personne ne tombait jamais. Une
  /// sauvegarde corrompue de la veille faisait perdre tout l'historique alors
  /// qu'une copie valable de la semaine précédente attendait juste à côté.
  ///
  /// On essaie aussi la suivante après une clé inconnue ou un schéma trop
  /// récent : l'archive précédente peut porter une autre version de clé, ou un
  /// schéma plus ancien donc lisible par cette version de l'application.
  ///
  /// L'erreur remontée est **la première**, celle de l'archive la plus
  /// récente : c'est celle qui décrit ce qui est réellement arrivé à la
  /// sauvegarde que l'inscrit attendait.
  Future<BackupSnapshotContent> restoreFirstReadable({
    required BackupTarget target,
    required List<RemoteArchive> candidates,
    required Directory workDir,
  }) async {
    Object? firstError;
    for (final archive in candidates) {
      try {
        return await restore(
          target: target,
          archive: archive,
          workDir: workDir,
        );
      } catch (e) {
        firstError ??= e;
        debugPrint('[Restore] ${archive.name} illisible ($e)'
            ' → tentative sur la précédente');
      }
    }
    throw firstError ??
        const BackupFormatInvalid('aucune archive à la destination');
  }

  /// Les archives de [alanyaID], de la plus récente à la plus ancienne.
  ///
  /// ── Deux corrections en une ──
  ///
  /// **Le tri se fait sur le nom**, comme la purge. Celle-ci s'en explique :
  /// l'heure de modification est réécrite au dépôt par certaines destinations.
  /// La restauration s'appuyait pourtant dessus, via l'ordre rendu par `list()`.
  /// Deux critères contradictoires pour désigner « la plus récente ».
  ///
  /// **Et le compte est filtré.** Un même téléphone peut porter deux comptes
  /// Alanya. La restauration ne regardait que l'extension, et pouvait donc
  /// désigner l'archive de l'autre : indéchiffrable — la clé est dérivée du
  /// compte, donc aucune fuite — mais un échec incompréhensible.
  ///
  /// [alanyaID] à zéro rend tout, trié : c'est le repli quand l'identifiant
  /// n'est pas connu, et il vaut mieux essayer que ne rien proposer.
  static List<RemoteArchive> candidatesFor(
    int alanyaID,
    List<RemoteArchive> all,
  ) {
    final prefix = 'alanya-backup-$alanyaID-';
    return all
        .where((a) => a.name.endsWith('.enc'))
        .where((a) => alanyaID == 0 || a.name.startsWith(prefix))
        .toList()
      ..sort((a, b) => b.name.compareTo(a.name));
  }

  /// Descriptif en clair de la dernière sauvegarde, ou `null` s'il n'y en a
  /// pas. Ne déchiffre rien et ne demande aucune clé.
  Future<BackupMeta?> readMeta(BackupTarget target, int alanyaID) async {
    final found = (await target.list())
        .where((a) => a.name == metaName(alanyaID))
        .firstOrNull;
    if (found == null) return null;

    final dir = await Directory.systemTemp.createTemp('alanya_meta_read');
    try {
      final file = await target.read(
        found.id,
        File(p.join(dir.path, found.name)),
      );
      return BackupMeta.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      // Un descriptif illisible ne doit pas masquer l'existence des archives :
      // l'appelant retombera sur la liste brute.
      return null;
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  /// `alanya-backup-<compte>-20260831T210400Z.enc`
  ///
  /// Horodatage compact et trié : l'ordre alphabétique des noms est l'ordre
  /// chronologique, ce dont la purge se sert pour ne pas dépendre d'une date
  /// de modification que la destination peut réécrire.
  static String archiveName(int alanyaID, DateTime at) {
    final u = at.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${u.year}${two(u.month)}${two(u.day)}'
        'T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
    return 'alanya-backup-$alanyaID-$stamp.enc';
  }

  static String metaName(int alanyaID) => 'alanya-backup-$alanyaID-latest.json';
}

/// Le dépôt s'est déroulé sans erreur mais la relecture ne concorde pas.
class BackupVerificationFailed implements Exception {
  final String reason;
  const BackupVerificationFailed(this.reason);

  @override
  String toString() => 'BackupVerificationFailed($reason)';
}
