import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../db/app_database.dart';
import '../connectivity_service.dart';
import 'backup_prefs_policy.dart';
import 'backup_schedule.dart';
import 'backup_service.dart';
import 'backup_snapshot.dart' show BackupMeta;
import 'backup_settings_store.dart';
import 'backup_snapshot.dart';
import 'backup_target.dart';
import 'downloads_mirror_target.dart';
import 'drive_backup_target.dart';
import 'local_folder_target.dart';

/// Déclenche les sauvegardes automatiques au retour de l'application au
/// premier plan.
///
/// ── Pourquoi ici, et pas dans une tâche de fond ──
///
/// La tentation était d'utiliser `workmanager`. Il exécute son rappel dans un
/// **isolat séparé** : ni fournisseurs, ni base ouverte, ni client d'API. Il
/// aurait fallu y reconstruire toute la chaîne — dont **une seconde
/// `AppDatabase` sur le même fichier pendant que l'application tourne**. Drift
/// avertit explicitement contre ça : deux connexions concurrentes sur la même
/// base, ce sont des courses d'écriture et une base éventuellement corrompue.
/// C'est la même famille de problème que l'échange du fichier restauré, qui
/// nous a déjà obligés à passer en deux temps.
///
/// La politique de sauvegarde est **temporelle**, pas événementielle : elle
/// demande « la dernière remonte-t-elle à plus d'une semaine ? ». Quelqu'un qui
/// ouvre Alanya au moins une fois par semaine obtient donc sa sauvegarde
/// hebdomadaire sans aucune machinerie de fond, sans dépendance nouvelle, sans
/// isolat et sans service de premier plan — la base pèse quelques mégaoctets,
/// l'affaire dure quelques secondes.
///
/// Le travail en arrière-plan reste possible plus tard, si l'usage réel montre
/// que trop d'inscrits ouvrent l'application moins souvent que leur fréquence
/// choisie. Ce serait alors une décision prise sur des chiffres, pas par
/// principe.
/// Ce qu'une tentative de sauvegarde a réellement produit.
///
/// Trois issues et non deux, parce que « écrit quelque part » et « écrit là où
/// l'inscrit l'a demandé » ne sont pas la même chose.
enum BackupRunResult {
  /// Déposée à la destination choisie.
  success,

  /// Drive était visé mais injoignable : une copie locale a été écrite.
  /// Les données sont sauvées, la destination voulue a été manquée.
  fallback,

  /// Rien n'a été écrit.
  failure,

  /// Une sauvegarde était déjà en cours. **Rien n'a échoué** — l'annoncer
  /// comme un échec enverrait l'inscrit chercher un problème inexistant.
  alreadyRunning,
}

/// Résultat d'une tentative, avec l'état qui en découle.
class BackupAttempt {
  final BackupRunResult result;
  final BackupMeta? meta;
  final BackupState state;

  const BackupAttempt(this.result, this.meta, this.state);

  bool get wroteSomething => result != BackupRunResult.failure;
}

class BackupRunner {
  final AppDatabase db;
  final BackupKeyProvider keys;
  final ConnectivityService connectivity;

  /// Déclare la sauvegarde au serveur. Sans elle, l'écran de restauration d'un
  /// futur téléphone ne saurait pas qu'une sauvegarde existe.
  final Future<void> Function(BackupMeta meta)? onSucceeded;

  /// Destination imposée. Réservée aux tests : en usage réel elle est nulle,
  /// et c'est le choix stocké de l'inscrit qui décide.
  final BackupTarget? target;

  /// Adresse du compte Alanya, pour pré-sélectionner le bon compte Google.
  ///
  /// Connaître l'adresse ne donne évidemment aucun droit sur le Drive — c'est
  /// Google qui accorde l'accès. Mais elle évite un sélecteur vide, et surtout
  /// l'erreur de compte : sauvegarder sur le mauvais Drive est le genre de
  /// méprise qu'on ne découvre qu'au moment de restaurer.
  final String? accountEmail;

  static const _store = BackupSettingsStore();
  static const _policy = BackupSchedulePolicy();

  /// Empêche deux sauvegardes simultanées.
  ///
  /// ── Pourquoi `static` ──
  ///
  /// Une sauvegarde est exclusive à **l'application** : une base, un fichier de
  /// travail, une destination, un descriptif `latest.json`. Or chaque appelant
  /// construit son propre `BackupRunner` — la tâche de fond le sien, l'écran de
  /// réglages le sien. Un verrou d'instance ne voyait donc jamais l'autre, et
  /// deux sauvegardes pouvaient se dérouler en parallèle sur les mêmes fichiers.
  ///
  /// Le dépôt Drive y est particulièrement sensible : `write` liste, décide, puis
  /// crée ou met à jour. Deux exécutions concurrentes décident toutes deux de
  /// « créer », et Drive accepte les homonymes — d'où **deux `latest.json`**
  /// dont `readMeta` prend ensuite un au hasard. Le descriptif affiché peut
  /// alors rester périmé indéfiniment, sans qu'aucune sauvegarde n'échoue.
  ///
  /// La course la plus probable ne vient même pas du bouton manuel : le
  /// gestionnaire de cycle de vie lance `_maybeRunBackup` en `unawaited`, sans
  /// garde. Deux retours au premier plan rapprochés, et la sauvegarde
  /// automatique se court après elle-même.
  ///
  /// ── Ce que ce verrou ne couvre pas ──
  ///
  /// Un isolat séparé : il faudrait alors un verrou de fichier. Et un dépôt
  /// bloqué sans délai d'expiration le retiendrait jusqu'au prochain démarrage
  /// du processus — le bon endroit pour traiter ce cas est le délai de l'appel
  /// réseau, pas un verrou qui se libère tout seul.
  static bool _running = false;

  /// Libère le verrou entre deux cas de test. Un état statique fuit sinon d'un
  /// test à l'autre, et le second échouerait sans rapport avec ce qu'il vérifie.
  @visibleForTesting
  static void releaseLockForTest() => _running = false;

  BackupRunner({
    required this.db,
    required this.keys,
    required this.connectivity,
    this.onSucceeded,
    this.target,
    this.accountEmail,
  });

  /// À appeler au passage en [AppLifecycleState.resumed], et une fois au
  /// démarrage. Ne fait rien si ce n'est pas dû.
  ///
  /// Rend `null` quand rien n'a été tenté — pas dû, réseau mesuré, sauvegarde
  /// déjà en cours — et le résultat de la tentative sinon.
  Future<BackupAttempt?> maybeRun({
    required int alanyaID,
    DateTime? now,
  }) async {
    if (_running || alanyaID == 0) return null;

    final frequency = await _store.frequency();
    final state = await _store.state();
    final at = now ?? DateTime.now().toUtc();
    // Mesuré avant l'appel : la politique est volontairement synchrone et sans
    // dépendance, c'est ce qui la rend éprouvable en quelques millisecondes.
    final unmetered = await connectivity.currentIsUnmetered;

    if (!_policy.shouldRun(
      now: at,
      frequency: frequency,
      state: state,
      isUnmetered: unmetered,
    )) {
      return null;
    }

    return runNow(alanyaID: alanyaID, now: at);
  }

  /// Exécute une sauvegarde **sans demander son avis à la politique**.
  ///
  /// Le chemin unique de l'automatique et du bouton « Sauvegarder maintenant ».
  /// Les avoir séparés ferait diverger la destination : l'écran de réglages
  /// pourrait déposer ailleurs que la tâche de fond, et personne ne le verrait
  /// avant le jour de la restauration.
  Future<BackupAttempt> runNow({
    required int alanyaID,
    DateTime? now,
  }) async {
    // Testé AVANT toute lecture, et posé juste après, sans `await` entre les
    // deux : Dart étant à fil unique, la séquence est atomique et aucun mutex
    // n'est nécessaire.
    if (_running) {
      return BackupAttempt(
          BackupRunResult.alreadyRunning, null, await _store.state());
    }
    // Une archive nommée `alanya-backup-0-….enc` serait invisible à toute
    // restauration. `maybeRun` s'en gardait déjà ; le bouton manuel, non.
    if (alanyaID == 0) {
      return BackupAttempt(
          BackupRunResult.failure, null, await _store.state());
    }
    _running = true;

    final at = now ?? DateTime.now().toUtc();
    final frequency = await _store.frequency();
    final state = await _store.state();
    try {
      final resolved = await _resolveTarget(
        state: state,
        frequency: frequency,
        now: at,
      );
      if (resolved == null) {
        // Drive injoignable ET copie de secours encore fraîche : inutile de
        // réécrire le même mégaoctet. On note l'échec, le réessai reprendra.
        final next = state.afterFailure(at);
        await _store.saveState(next);
        return BackupAttempt(BackupRunResult.failure, null, next);
      }

      final prefs = await SharedPreferences.getInstance();
      final work = Directory(
        p.join((await getTemporaryDirectory()).path, 'backup_work'),
      );

      final outcome = await BackupService(db: db, keys: keys).run(
        target: resolved.target,
        alanyaID: alanyaID,
        prefs: collectBackedUpPrefs(prefs.get),
        workDir: work,
        now: at,
        onSucceeded: onSucceeded,
      );

      late final BackupRunResult result;
      late final BackupState next;
      if (!outcome.succeeded) {
        result = BackupRunResult.failure;
        next = state.afterFailure(at);
      } else if (resolved.isFallback) {
        result = BackupRunResult.fallback;
        next = state.afterFallback(at);
      } else {
        result = BackupRunResult.success;
        next = state.afterSuccess(at);
      }
      await _store.saveState(next);
      return BackupAttempt(result, outcome.meta, next);
    } catch (_) {
      // Une sauvegarde automatique ne doit jamais remonter jusqu'à l'écran :
      // elle est censée passer inaperçue. L'échec est enregistré, et c'est la
      // politique qui décidera plus tard s'il faut en parler.
      final next = state.afterFailure(at);
      await _store.saveState(next);
      return BackupAttempt(BackupRunResult.failure, null, next);
    } finally {
      _running = false;
    }
  }

  /// Choisit où déposer, en disant si c'est un pis-aller.
  ///
  /// Rend `null` quand il n'y a rien à faire : Drive est injoignable et la
  /// copie de secours est plus jeune que l'intervalle choisi. Le réessai monte
  /// à 15 min, 1 h, 6 h, 12 h — réécrire la base en local à chaque passage
  /// userait le stockage pour rien.
  Future<_ResolvedTarget?> _resolveTarget({
    required BackupState state,
    required BackupFrequency frequency,
    required DateTime now,
  }) async {
    final forced = target;
    if (forced != null) return _ResolvedTarget(forced, isFallback: false);

    if (await _store.destination() == BackupDestination.device) {
      return _ResolvedTarget(await localTarget(), isFallback: false);
    }

    try {
      final drive = await DriveBackupTarget.connect(accountEmail: accountEmail);
      if (drive != null) return _ResolvedTarget(drive, isFallback: false);
    } catch (_) {
      // Réseau coupé, autorisation révoquée, quota : traité comme une absence
      // de Drive. La distinction n'intéresse personne ici, seul le repli compte.
    }

    final lastFallback = state.lastFallbackAt;
    final interval = frequency.interval;
    if (lastFallback != null &&
        interval != null &&
        now.difference(lastFallback) < interval) {
      return null;
    }
    return _ResolvedTarget(await localTarget(), isFallback: true);
  }

  /// `Documents/Alanya/Sauvegardes` — la destination de l'inscrit qui n'a pas
  /// de compte Google, et celle de tout le monde tant que Drive n'est pas
  /// branché.
  /// Destination **en lecture seule**, pour afficher un descriptif ou lister
  /// des archives. N'écrit jamais, et ne décide de rien.
  ///
  /// Elle suit le choix stocké : si l'inscrit a choisi Drive, on le tente en
  /// silence et on retombe en local pour la lecture seulement. C'est sans
  /// danger — lire au mauvais endroit ne rend rien de faux, ça rend moins.
  /// L'écriture, elle, passe par [runNow], qui distingue le dépôt voulu du
  /// pis-aller et le dit.
  static Future<BackupTarget> readTarget({String? accountEmail}) async {
    if (await const BackupSettingsStore().destination() ==
        BackupDestination.drive) {
      try {
        final drive =
            await DriveBackupTarget.connect(accountEmail: accountEmail);
        if (drive != null) return drive;
      } catch (_) {
        // Rien de grave : on lira la copie locale, qui existe précisément
        // pour ces moments-là.
      }
    }
    return localTarget();
  }

  /// Stockage de l'appareil, doublé dans `Download`.
  ///
  /// Le dossier privé est effacé à la désinstallation : une sauvegarde qui n'y
  /// serait que là disparaîtrait au moment précis où elle sert. Le miroir lui
  /// survit, et l'inscrit peut le recopier ailleurs.
  static Future<BackupTarget> localTarget() async {
    final base = await getApplicationDocumentsDirectory();
    return DownloadsMirrorTarget(
      LocalFolderTarget(Directory(p.join(base.path, 'Alanya', 'Sauvegardes'))),
    );
  }
}


/// Une destination et la façon dont on y est arrivé.
class _ResolvedTarget {
  final BackupTarget target;

  /// Vrai quand Drive était visé et qu'on écrit en local faute de mieux.
  final bool isFallback;

  const _ResolvedTarget(this.target, {required this.isFallback});
}
