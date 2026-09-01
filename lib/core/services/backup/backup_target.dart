import 'dart:io';

/// Où l'inscrit a choisi que ses sauvegardes aillent.
///
/// ── Pourquoi c'est un choix stocké, et non le résultat d'un essai ──
///
/// Le code se contentait auparavant de tenter Drive puis de retomber en local
/// sans rien dire. L'inscrit croyait ses données chez Google alors qu'elles
/// étaient sur son téléphone — c'est-à-dire au seul endroit qui ne protège ni
/// de la perte, ni du vol, ni de la casse. Pire : l'écriture locale comptant
/// comme un succès, l'alerte prévue pour signaler une série d'échecs ne se
/// déclenchait jamais. Le repli éteignait l'alarme qu'il aurait dû sonner.
///
/// Une destination explicite rend cette confusion impossible : on sait ce qui
/// était visé, donc on sait quand on l'a manqué.
enum BackupDestination {
  /// Le dossier `Alanya` du Drive de l'inscrit. Seule destination qui met les
  /// données **hors** du téléphone.
  drive,

  /// Le stockage de l'appareil, doublé dans `Download/Alanya/Sauvegardes`.
  /// Le filet de qui n'a pas de compte Google, ou n'en veut pas.
  device;

  static BackupDestination parse(String? raw) => BackupDestination.values
      .firstWhere((d) => d.name == raw, orElse: () => BackupDestination.device);
}

/// Une archive posée sur une destination de sauvegarde.
///
/// [id] est opaque et propre à la destination : identifiant de fichier Drive,
/// chemin absolu en local. L'appelant ne l'interprète jamais, il le rend tel
/// quel à [BackupTarget.read] ou [BackupTarget.delete].
class RemoteArchive {
  final String id;
  final String name;
  final int bytes;
  final DateTime modifiedAt;

  const RemoteArchive({
    required this.id,
    required this.name,
    required this.bytes,
    required this.modifiedAt,
  });
}

/// Destination d'une sauvegarde ou d'une archive d'export.
///
/// ── Pourquoi cette interface existe ──
///
/// Toute la conception ne touche Google Drive que par quatre gestes : lister,
/// écrire, lire, supprimer. Les isoler derrière une abstraction n'est pas de
/// l'architecture décorative, c'est une assurance sur un point précis et
/// encore non vérifié : sur un téléphone neuf, l'application retrouve-t-elle
/// dans le Drive de l'inscrit les fichiers qu'elle y avait déposés depuis
/// l'ancien ? Le champ d'accès retenu la limite aux fichiers qu'elle a créés,
/// et il reste à confirmer que ce droit suit **l'application** (identifiant
/// client OAuth) et non **l'installation**.
///
/// Si la réponse est mauvaise, il faudra basculer sur le dossier caché de
/// l'application. Avec cette interface, ça coûte une classe. Sans elle, ça
/// coûterait la restauration entière.
///
/// ── Et elle ne coûte rien de plus ──
///
/// Un inscrit sans compte Google doit pouvoir sauvegarder quand même, dans le
/// stockage de son téléphone. Cette implémentation-là était requise de toute
/// façon : l'abstraction protège du risque Drive par pure retombée.
///
/// ── Ce qu'elle rend possible en test ──
///
/// Les scénarios de restauration — archive tronquée, clé inconnue, schéma
/// futur, mauvais compte, destination vide — ne sont jouables que si le
/// service de restauration reçoit sa destination **en paramètre** plutôt que
/// d'aller chercher Drive lui-même. Sans cette règle, ils ne seraient
/// rejouables qu'à la main sur un vrai téléphone avec un vrai compte Google,
/// autant dire jamais.
abstract class BackupTarget {
  /// Nom lisible de la destination, pour l'affichage (« Google Drive »,
  /// « Stockage de l'appareil »).
  String get label;

  /// Les archives présentes, plus récente d'abord.
  Future<List<RemoteArchive>> list();

  /// Dépose [local] sous le nom [name] et retourne l'archive créée.
  Future<RemoteArchive> write(File local, String name);

  /// Rapatrie l'archive [id] dans [into] et retourne le fichier écrit.
  Future<File> read(String id, File into);

  /// Suppression définitive. N'est appelée que sur une archive dont on n'a
  /// plus besoin — jamais pour faire de la place à l'insu de l'inscrit.
  Future<void> delete(String id);
}
