import 'dart:io';

import 'package:path/path.dart' as p;

import 'backup_target.dart';

/// Destination « stockage de l'appareil ».
///
/// Sert deux cas qui n'ont rien à voir mais veulent le même code :
///
/// 1. **L'inscrit sans compte Google.** Tous n'en ont pas, et certains
///    refuseront d'en connecter un. Ils ne doivent pas rester sans filet : la
///    même archive, au même format et avec le même chiffrement, est écrite
///    dans un dossier du téléphone, à charge pour l'inscrit de la recopier où
///    il veut.
/// 2. **Les tests.** Un dossier temporaire suffit à rejouer une sauvegarde et
///    une restauration complètes, sans réseau, sans compte Google et sans
///    appareil.
class LocalFolderTarget implements BackupTarget {
  /// Dossier de dépôt. Créé à la première écriture, jamais avant : un dossier
  /// vide qui apparaît dans les fichiers de l'inscrit sans qu'il ait rien
  /// demandé est du bruit.
  final Directory directory;

  const LocalFolderTarget(this.directory);

  @override
  String get label => directory.path;

  @override
  Future<List<RemoteArchive>> list() async {
    if (!await directory.exists()) return const [];
    final out = <RemoteArchive>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      out.add(RemoteArchive(
        id: entity.path,
        name: p.basename(entity.path),
        bytes: stat.size,
        modifiedAt: stat.modified,
      ));
    }
    out.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return out;
  }

  @override
  Future<RemoteArchive> write(File local, String name) async {
    await directory.create(recursive: true);
    final destination = File(p.join(directory.path, name));
    // `copy` et non `rename` : la source est un fichier de travail dont
    // l'appelant reste propriétaire, et un `rename` échoue de toute façon
    // entre deux systèmes de fichiers.
    final written = await local.copy(destination.path);
    final stat = await written.stat();
    return RemoteArchive(
      id: written.path,
      name: name,
      bytes: stat.size,
      modifiedAt: stat.modified,
    );
  }

  @override
  Future<File> read(String id, File into) async {
    final source = File(id);
    if (!await source.exists()) {
      throw BackupArchiveNotFound(id);
    }
    await into.parent.create(recursive: true);
    return source.copy(into.path);
  }

  @override
  Future<void> delete(String id) async {
    final file = File(id);
    // Absente = déjà supprimée. Ce n'est pas une erreur : la suppression est
    // idempotente, sans quoi une reprise après coupure échouerait sur un
    // fichier qu'elle avait justement fini d'effacer.
    if (await file.exists()) await file.delete();
  }
}

/// L'archive demandée n'existe plus à la destination.
///
/// Distinguée d'une erreur d'entrée-sortie : l'inscrit a pu supprimer la
/// sauvegarde depuis son Drive, et l'écran doit alors le dire plutôt que
/// d'afficher une panne.
class BackupArchiveNotFound implements Exception {
  final String id;
  const BackupArchiveNotFound(this.id);

  @override
  String toString() => 'BackupArchiveNotFound($id)';
}
