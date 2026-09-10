import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'backup_target.dart';
import 'local_folder_target.dart' show BackupArchiveNotFound;

/// Double chaque sauvegarde dans `Download/Alanya/Sauvegardes`.
///
/// ── Le problème que ça règle ──
///
/// Le magasin de travail vit dans le dossier privé de l'application. Android
/// l'efface **intégralement à la désinstallation** : une sauvegarde qui n'y
/// serait qu'là disparaîtrait avec l'application, c'est-à-dire exactement au
/// moment où elle sert.
///
/// Le dossier `Download` survit, lui, et l'inscrit le voit dans son
/// gestionnaire de fichiers. Il peut le recopier sur un ordinateur, une clé
/// USB, l'envoyer par messagerie — c'est sa copie à lui.
///
/// ── Pourquoi doubler plutôt que déplacer ──
///
/// Après une réinstallation, l'application perd l'attribution de ses fichiers
/// dans `Download` : elle ne peut plus les **lister** toute seule, même s'ils
/// sont physiquement là. Y déplacer le magasin casserait donc le
/// fonctionnement normal — purge, relecture, descriptif — pour un gain qui ne
/// se manifeste qu'une fois dans la vie d'un téléphone.
///
/// On garde donc le magasin privé pour travailler, et `Download` comme copie
/// durable, désignée à la main via [PickedArchiveTarget] le jour d'une
/// restauration après réinstallation. Le surcoût est d'environ un mégaoctet
/// par sauvegarde.
///
/// ── Ce que ça ne remplace pas ──
///
/// Google Drive. La copie reste sur le téléphone : elle ne survit ni à une
/// perte, ni à un vol, ni à une casse. C'est le filet de l'inscrit **sans
/// compte Google**, pas la mise à l'abri.
class DownloadsMirrorTarget implements BackupTarget {
  static const _channel = MethodChannel('com.alanya/media_export');
  static const _subdir = 'Alanya/Sauvegardes';

  /// Magasin réel. Toutes les lectures et suppressions lui reviennent.
  final BackupTarget primary;

  const DownloadsMirrorTarget(this.primary);

  @override
  String get label => primary.label;

  @override
  Future<List<RemoteArchive>> list() => primary.list();

  @override
  Future<File> read(String id, File into) => primary.read(id, into);

  /// Ne supprime **que** dans le magasin de travail.
  ///
  /// La copie de `Download` appartient à l'inscrit dès qu'elle y est posée :
  /// la purge à deux versions ne doit pas décider à sa place de ce qu'il garde
  /// dans ses propres fichiers.
  @override
  Future<void> delete(String id) => primary.delete(id);

  @override
  Future<RemoteArchive> write(File local, String name) async {
    final archive = await primary.write(local, name);
    // Le miroir ne doit jamais faire échouer une sauvegarde réussie : le
    // magasin de travail a déjà l'archive, et c'est lui qui compte au
    // quotidien.
    await _mirror(local, name);
    return archive;
  }

  Future<void> _mirror(File local, String name) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('saveToDownloads', {
        'path': local.path,
        'fileName': name,
        // Type générique : ce n'est ni une image ni un document connu, et le
        // déclarer autrement ferait apparaître l'archive dans la galerie.
        'mimeType': 'application/octet-stream',
        'subdir': _subdir,
      });
    } catch (_) {
      // Permission refusée, stockage plein, appareil exotique : tant pis. La
      // sauvegarde existe, seule sa copie durable manque.
    }
  }
}

/// Enveloppe une archive **désignée à la main** par l'inscrit.
///
/// Sert le seul cas où l'application ne peut pas retrouver la sauvegarde toute
/// seule : après une réinstallation, elle a perdu l'attribution de ses fichiers
/// dans `Download`. L'inscrit pointe le fichier, et cette destination le
/// présente comme s'il venait d'un magasin ordinaire.
///
/// C'est la troisième implémentation de [BackupTarget], et rien d'autre ne
/// bouge : le déchiffrement, le contrôle de version de clé et le dépôt en deux
/// temps ne savent pas d'où vient l'archive.
class PickedArchiveTarget implements BackupTarget {
  final File file;

  const PickedArchiveTarget(this.file);

  @override
  String get label => p.basename(file.path);

  @override
  Future<List<RemoteArchive>> list() async {
    if (!await file.exists()) return const [];
    final stat = await file.stat();
    return [
      RemoteArchive(
        id: file.path,
        name: p.basename(file.path),
        bytes: stat.size,
        modifiedAt: stat.modified,
      ),
    ];
  }

  @override
  Future<File> read(String id, File into) async {
    if (!await file.exists()) throw BackupArchiveNotFound(id);
    await into.parent.create(recursive: true);
    return file.copy(into.path);
  }

  /// Sans effet : le fichier appartient à l'inscrit, il l'a désigné pour être
  /// lu. Le supprimer serait une prise de liberté avec ses propres fichiers.
  @override
  Future<void> delete(String id) async {}

  /// Sans objet : on ne sauvegarde jamais vers un fichier choisi à la main.
  @override
  Future<RemoteArchive> write(File local, String name) =>
      throw UnsupportedError('PickedArchiveTarget est en lecture seule');
}
