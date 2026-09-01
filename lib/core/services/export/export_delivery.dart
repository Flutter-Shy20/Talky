import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Où l'archive assemblée est remise à l'inscrit.
enum ExportDestination {
  /// Sélecteur de partage du système. Il contient déjà Drive, la messagerie,
  /// « Enregistrer dans Fichiers » — donc le dépôt sur Drive vient gratuitement
  /// tant que l'intégration OAuth n'est pas écrite.
  share,

  /// Dossier `Download/Alanya` du téléphone. Sortie toujours disponible, y
  /// compris quand le partage d'un fichier volumineux échoue.
  downloads,
}

/// Remet l'archive à l'inscrit selon la destination choisie.
///
/// Séparé du travail d'export : l'assemblage doit rester testable sans qu'un
/// canal de plateforme ni une feuille de partage n'entrent en jeu.
class ExportDelivery {
  static const _channel = MethodChannel('com.alanya/media_export');

  /// Sous-dossier de `Download/`, aligné sur celui qu'utilise déjà
  /// `AlanyaMediaExportService` pour les médias unitaires.
  static const _downloadsSubdir = 'Alanya';

  const ExportDelivery();

  /// Dossier de travail où l'archive est assemblée avant remise.
  ///
  /// Le cache et non les documents : une archive déjà partagée n'a plus de
  /// raison d'occuper l'espace de l'inscrit, et le système peut la reprendre.
  static Future<Directory> workingDirectory() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'exports'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Démarre le service de premier plan qui protège un export long.
  ///
  /// Sans lui, Android suspend puis tue le processus dès que l'inscrit
  /// bascule sur une autre application, et l'archive en cours est perdue.
  /// Échoue en silence : mieux vaut un export fragile qu'un export impossible.
  static Future<void> startForegroundTask() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('startExportService');
    } catch (_) {}
  }

  static Future<void> updateForegroundTask(int done, int total) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel
          .invokeMethod('updateExportService', {'done': done, 'total': total});
    } catch (_) {}
  }

  /// À appeler **dans un `finally`** : un service de premier plan oublié
  /// laisse une notification permanente que l'inscrit ne peut pas retirer.
  static Future<void> stopForegroundTask() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopExportService');
    } catch (_) {}
  }

  /// Octets libres sur le volume portant [path], ou `null` si la mesure
  /// échoue ou n'est pas disponible sur cette plateforme.
  ///
  /// `dart:io` n'expose pas `statfs` : seule la plateforme sait répondre. Un
  /// `null` signifie « je ne sais pas » et non « il n'y a plus de place » —
  /// l'assemblage passe alors sans contrôle plutôt que d'être refusé à tort.
  static Future<int?> freeSpaceBytes(String path) async {
    if (!Platform.isAndroid) return null;
    try {
      final bytes =
          await _channel.invokeMethod<int>('freeSpaceBytes', {'path': path});
      return (bytes == null || bytes < 0) ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> deliver({
    required File archive,
    required ExportDestination destination,
    String? subject,
  }) async {
    switch (destination) {
      case ExportDestination.share:
        await SharePlus.instance.share(
          ShareParams(files: [XFile(archive.path)], subject: subject),
        );
      case ExportDestination.downloads:
        await _saveToDownloads(archive);
    }
  }

  Future<void> _saveToDownloads(File archive) async {
    if (!Platform.isAndroid) {
      // iOS n'a pas de dossier « Téléchargements » partagé : la seule sortie
      // est la feuille de partage, qui propose « Enregistrer dans Fichiers ».
      throw const ExportDeliveryUnsupported();
    }
    final ok = await _channel.invokeMethod<bool>('saveToDownloads', {
      'path': archive.path,
      'fileName': p.basename(archive.path),
      'mimeType': 'application/zip',
      'subdir': _downloadsSubdir,
    });
    if (ok != true) throw const ExportDeliveryFailed();
  }

  /// Nom de fichier de l'archive.
  ///
  /// Daté et borné : posé à côté de trois autres exports dans un dossier de
  /// téléchargements, un nom générique ne dirait plus lequel est lequel.
  static String archiveName({
    required int alanyaID,
    DateTime? from,
    DateTime? to,
  }) {
    final period = (from != null && to != null)
        ? '${_day(from)}_${_day(to)}'
        : _day(DateTime.now());
    return 'alanya-export-$alanyaID-$period.zip';
  }

  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// La destination n'existe pas sur cette plateforme.
class ExportDeliveryUnsupported implements Exception {
  const ExportDeliveryUnsupported();
  @override
  String toString() => 'ExportDeliveryUnsupported';
}

/// La plateforme a refusé d'écrire l'archive.
class ExportDeliveryFailed implements Exception {
  const ExportDeliveryFailed();
  @override
  String toString() => 'ExportDeliveryFailed';
}
