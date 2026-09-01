import 'dart:io';
import 'dart:typed_data';

import 'backup_prefs_policy.dart';
import 'backup_snapshot.dart';

/// Écrit une sauvegarde restaurée par-dessus la base locale.
///
/// ── Ce que fait vraiment une restauration ──
///
/// Remplacer un fichier SQLite ouvert n'est pas une copie. Trois précautions
/// sont indispensables, et l'oubli de la deuxième est la faute classique :
///
/// 1. **Fermer la base** avant de toucher au fichier.
/// 2. **Supprimer les fichiers annexes `-wal` et `-shm`.** Ils appartiennent à
///    l'ancienne base. Laissés en place, SQLite tenterait d'appliquer un
///    journal d'écriture anticipée étranger à la base fraîchement écrite, et
///    la corromprait — silencieusement, avec un message d'erreur qui
///    n'apparaîtra que bien plus tard.
/// 3. **Écrire à côté puis renommer**, pour qu'une coupure ne laisse jamais un
///    fichier de base à moitié écrit là où l'application ira le chercher.
///
/// ── Pourquoi ce service reçoit tout en paramètres ──
///
/// Il ne va chercher ni la destination, ni la base, ni les préférences dans un
/// singleton. Sans cette règle, les scénarios qui comptent — archive tronquée,
/// clé inconnue, schéma futur, coupure en pleine écriture — ne seraient
/// rejouables qu'à la main sur un vrai téléphone avec un vrai compte Google.
/// Autant dire jamais.
class RestoreService {
  /// Ferme la base pour libérer le fichier. Rendue par l'appelant, qui seul
  /// sait quelle instance est ouverte.
  final Future<void> Function() closeDatabase;

  /// Applique les préférences restaurées. Déjà filtrées par la liste blanche.
  final Future<void> Function(Map<String, Object> prefs) applyPrefs;

  const RestoreService({
    required this.closeDatabase,
    required this.applyPrefs,
  });

  /// Installe [content] à la place de la base située en [databaseFile].
  ///
  /// [markInProgress] et [markDone] encadrent l'écriture : c'est entre les
  /// deux que la base est dans un état intermédiaire, et c'est cet intervalle
  /// que le redémarrage doit savoir détecter.
  Future<void> apply({
    required File databaseFile,
    required BackupSnapshotContent content,
    required Future<void> Function() markInProgress,
    required Future<void> Function() markDone,
  }) async {
    if (content.database.isEmpty) {
      throw const RestoreFailed('sauvegarde vide');
    }

    // Écrit à côté, avant toute destruction : si la place manque ou si le
    // courant s'arrête ici, l'ancienne base est encore intacte.
    final incoming = File('${databaseFile.path}.incoming');
    await incoming.writeAsBytes(content.database, flush: true);

    await markInProgress();
    try {
      await closeDatabase();
      await _removeSidecars(databaseFile);

      // `rename` sur le même système de fichiers : l'ancienne base n'est
      // jamais absente et à moitié réécrite, elle est remplacée d'un coup.
      await incoming.rename(databaseFile.path);

      if (content.prefs.isNotEmpty) {
        await applyPrefs(filterRestorablePrefs(content.prefs));
      }
      await markDone();
    } catch (e) {
      // L'état reste `inProgress` : le prochain démarrage videra et
      // reproposera, ce qui est la seule issue sûre après une écriture
      // interrompue.
      if (await incoming.exists()) {
        await incoming.delete();
      }
      throw RestoreFailed('$e');
    }
  }

  /// Dépose la base restaurée **à côté** de l'actuelle, pour mise en place au
  /// prochain démarrage.
  ///
  /// C'est le chemin réellement emprunté par l'application, et [apply] ne sert
  /// qu'aux cas où la base n'est pas encore ouverte (tests, outillage).
  ///
  /// ── Pourquoi en deux temps ──
  ///
  /// `AppDatabase` est un champ `late final` créé au démarrage : on ne
  /// remplace pas son instance à chaud, et fermer la connexion ne suffirait
  /// pas — tout ce qui la détient continuerait de pointer sur un objet fermé.
  /// Poser le fichier puis l'échanger au lancement suivant, **avant que quoi
  /// que ce soit ne l'ouvre**, supprime la question au lieu de la gérer. C'est
  /// le procédé d'une mise à jour de programme, et il ne laisse aucune fenêtre
  /// de course.
  Future<void> stagePending({
    required File databaseFile,
    required BackupSnapshotContent content,
    required Future<void> Function() markPendingSwap,
  }) async {
    if (content.database.isEmpty) {
      throw const RestoreFailed('sauvegarde vide');
    }
    if (!looksLikeSqlite(content.database)) {
      // Refusé avant d'écrire : installer un contenu qui n'ouvrira jamais
      // rendrait l'application inutilisable au lancement suivant, sans recours.
      throw const RestoreFailed('le contenu restauré n\'est pas une base');
    }

    final incoming = File('${databaseFile.path}.incoming');
    await incoming.writeAsBytes(content.database, flush: true);

    // Les préférences sont appliquées tout de suite : elles ne dépendent pas
    // de la base et leur perte lors d'un redémarrage serait dommage.
    if (content.prefs.isNotEmpty) {
      await applyPrefs(filterRestorablePrefs(content.prefs));
    }
    await markPendingSwap();
  }

  /// Met en place une base déposée par [stagePending].
  ///
  /// À appeler **au tout début du démarrage**, avant la construction de
  /// l'arbre de fournisseurs et avant la moindre requête. Ne fait rien s'il
  /// n'y a pas de base en attente.
  ///
  /// Retourne `true` si un échange a eu lieu.
  static Future<bool> applyPendingSwap(File databaseFile) async {
    final incoming = File('${databaseFile.path}.incoming');
    if (!await incoming.exists()) return false;

    final bytes = await incoming.readAsBytes();
    if (!looksLikeSqlite(bytes)) {
      // Dépôt corrompu : on l'écarte sans toucher à la base en place.
      await incoming.delete();
      return false;
    }

    await _removeSidecars(databaseFile);
    await incoming.rename(databaseFile.path);
    return true;
  }

  /// Efface la base et ses annexes après une restauration interrompue.
  ///
  /// Une base à moitié restaurée fait sauter le rattrapage de synchronisation
  /// pour les conversations déjà écrites : les trous deviennent permanents.
  /// Repartir d'une base vide coûte un rapatriement complet, ce qui est
  /// infiniment préférable à un historique troué en silence.
  Future<void> wipe(File databaseFile) async {
    await closeDatabase();
    await _removeSidecars(databaseFile);
    if (await databaseFile.exists()) await databaseFile.delete();
    final incoming = File('${databaseFile.path}.incoming');
    if (await incoming.exists()) await incoming.delete();
  }

  /// Journal d'écriture anticipée et mémoire partagée de SQLite.
  static Future<void> _removeSidecars(File databaseFile) async {
    for (final suffix in const ['-wal', '-shm']) {
      final f = File('${databaseFile.path}$suffix');
      if (await f.exists()) await f.delete();
    }
  }
}

/// La restauration n'a pas abouti. L'état reste intermédiaire : le prochain
/// démarrage devra vider et reproposer.
class RestoreFailed implements Exception {
  final String reason;
  const RestoreFailed(this.reason);

  @override
  String toString() => 'RestoreFailed($reason)';
}

/// Aide de test et de diagnostic : la base restaurée est-elle plausible ?
///
/// Un fichier SQLite commence toujours par cette signature. Le vérifier avant
/// d'écrire évite d'installer un contenu qui n'ouvrira jamais.
bool looksLikeSqlite(Uint8List bytes) {
  const header = 'SQLite format 3';
  if (bytes.length < header.length) return false;
  for (var i = 0; i < header.length; i++) {
    if (bytes[i] != header.codeUnitAt(i)) return false;
  }
  return true;
}
