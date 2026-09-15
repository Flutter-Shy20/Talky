import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../errors/error_kind.dart';

/// Copie un média sélectionné vers un dossier outbox durable avant upload.
///
/// Les chemins renvoyés par le Photo Picker peuvent expirer ; cette copie
/// garantit que le fichier reste lisible pendant tout l'upload (séquentiel ou
/// parallèle).
///
/// [outboxDirectory] est réservé aux tests (évite path_provider en unit test).
Future<File> stageMediaFile(
  File source, {
  Directory? outboxDirectory,
}) async {
  if (!source.existsSync()) {
    // Le chemin du fichier partait à l'écran. Il n'apprend rien à
    // l'utilisateur et expose l'arborescence de l'appareil.
    throw MediaStagingException('fichier source absent: ${source.path}');
  }

  final outboxDir = outboxDirectory ?? await _outboxDirectory();
  if (!outboxDir.existsSync()) {
    await outboxDir.create(recursive: true);
  }
  final ext = p.extension(source.path).toLowerCase();
  final safeExt = ext.isNotEmpty ? ext : '';
  final name =
      'outbox_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}$safeExt';
  final dest = File(p.join(outboxDir.path, name));

  try {
    await source.copy(dest.path);
  } on FileSystemException catch (e) {
    throw MediaStagingException('copie impossible: ${e.message}', cause: e);
  }

  if (!dest.existsSync()) {
    throw MediaStagingException('copie vide: ${dest.path}');
  }
  return dest;
}

/// Copie plusieurs fichiers en parallèle.
Future<List<File>> stageMediaFiles(List<File> sources) {
  return Future.wait(sources.map(stageMediaFile));
}

Future<Directory> _outboxDirectory() async {
  final base = await getTemporaryDirectory();
  final dir = Directory(p.join(base.path, 'talky_outbox'));
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// Échec de mise en outbox d'un média.
///
/// [message] est un texte de **journal**, pas d'écran : il contient le chemin
/// du fichier, qui n'apprend rien à l'utilisateur et expose l'arborescence de
/// l'appareil. C'est le presenter qui choisit ce qui s'affiche, à partir de
/// [kind].
class MediaStagingException implements Exception {
  MediaStagingException(this.message, {this.cause});

  final String message;
  final Object? cause;

  /// Toujours un problème de stockage : fichier disparu, copie refusée, disque
  /// plein. Le presenter en tire « Vérifiez l'espace disponible ».
  ErrorKind get kind => ErrorKind.stockage;

  @override
  String toString() => 'MediaStagingException: $message';
}
