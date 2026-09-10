import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/db/app_database.dart';
import '../../core/services/backup/backup_crypto.dart';
import '../../core/services/backup/backup_service.dart';
import '../../core/services/backup/backup_snapshot.dart';
import '../../core/services/backup/backup_target.dart';
import '../../core/services/backup/downloads_mirror_target.dart';
import '../../core/services/backup/drive_backup_target.dart';
import '../../core/services/backup/restore_service.dart';
import '../../core/services/backup/restore_state.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/byte_format.dart';
import '../../l10n/app_localizations.dart';

/// Ce que le serveur sait d'une sauvegarde, avant toute connexion Google.
class BackupAnnouncement {
  final DateTime lastAt;
  final int bytes;
  final int? messageCount;

  /// Adresse Google masquée (`a•••@gmail.com`), telle que le serveur la garde.
  /// Permet de dire « connectez-vous avec ce compte-là » au lieu d'un
  /// « aucune sauvegarde trouvée » indiscernable d'une absence réelle.
  final String? accountHint;

  const BackupAnnouncement({
    required this.lastAt,
    required this.bytes,
    this.messageCount,
    this.accountHint,
  });

  static BackupAnnouncement? fromJson(Map<String, dynamic> json) {
    if (json['hasBackup'] != true) return null;
    final at = DateTime.tryParse(json['lastAt']?.toString() ?? '');
    if (at == null) return null;
    return BackupAnnouncement(
      lastAt: at,
      bytes: int.tryParse(json['bytes']?.toString() ?? '') ?? 0,
      messageCount: int.tryParse(json['messageCount']?.toString() ?? ''),
      accountHint: json['accountHint']?.toString(),
    );
  }
}

/// Étape **bloquante** de restauration, insérée entre l'authentification et
/// l'entrée dans l'application.
///
/// ── Pourquoi bloquante ──
///
/// Parce que rien ne tourne encore. La synchronisation n'a pas démarré, le
/// socket n'est pas connecté, `ChatRepository` n'est pas lié. Restaurer ici,
/// c'est écrire dans une maison vide ; le faire plus tard imposerait un verrou,
/// une reprise de curseur et un arbitrage entre deux écrivains. Quelques
/// secondes d'attente achètent la disparition d'une classe entière de bugs.
///
/// ── Pourquoi il y a toujours une porte de sortie ──
///
/// Une étape bloquante sans échappatoire enferme dehors l'inscrit dont la
/// sauvegarde est corrompue, chiffrée avec une clé disparue, ou simplement
/// trop récente pour cette version. « Ignorer et continuer » n'est donc pas
/// une politesse : c'est ce qui empêche l'application de devenir inutilisable.
class RestoreScreen extends StatefulWidget {
  final AppDatabase db;
  final BackupKeyProvider keys;
  final BackupTarget target;
  final BackupAnnouncement announcement;

  /// Appelé quand l'inscrit refuse, ou quand la restauration échoue et qu'il
  /// choisit de continuer sans. L'application poursuit son démarrage normal.
  final VoidCallback onSkip;

  const RestoreScreen({
    super.key,
    required this.db,
    required this.keys,
    required this.target,
    required this.announcement,
    required this.onSkip,
  });

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  static const _state = RestoreStateStore();

  bool _running = false;
  bool _staged = false;
  String? _error;

  /// Archive désignée à la main, quand l'application ne peut pas la retrouver
  /// seule — après une réinstallation, elle a perdu l'attribution de ses
  /// fichiers dans `Download`.
  BackupTarget? _picked;

  BackupTarget get _target => _picked ?? widget.target;

  Future<void> _restore() async {
    final l10n = context.l10n;
    setState(() {
      _running = true;
      _error = null;
    });

    try {
      final archives = (await _target.list())
          .where((a) => a.name.endsWith('.enc'))
          .toList();
      if (archives.isEmpty) {
        throw const BackupFormatInvalid('aucune archive à la destination');
      }

      final work = Directory(
        p.join((await getTemporaryDirectory()).path, 'restore_work'),
      );
      final content = await BackupService(db: widget.db, keys: widget.keys)
          .restore(
        target: _target,
        archive: archives.first,
        workDir: work,
      );

      await RestoreService(
        // La base n'est pas remplacée à chaud : le fichier est déposé à côté
        // et mis en place au prochain démarrage, avant que quoi que ce soit ne
        // l'ouvre. D'où l'absence de fermeture ici.
        closeDatabase: () async {},
        applyPrefs: _applyPrefs,
      ).stagePending(
        databaseFile: await appDatabaseFile(),
        content: content,
        markPendingSwap: () =>
            _state.setStage(RestoreStage.pendingSwap),
      );

      if (!mounted) return;
      setState(() {
        _running = false;
        _staged = true;
      });
    } on BackupSchemaTooRecent {
      _fail(l10n.restoreTooRecent);
    } on BackupAuthenticationFailed {
      _fail(l10n.restoreKeyUnknown);
    } on BackupFormatInvalid {
      _fail(l10n.restoreFailedMessage);
    } catch (_) {
      _fail(l10n.restoreFailedMessage);
    }
  }

  /// Connecte un compte Google et cherche la sauvegarde dans son Drive.
  ///
  /// Interactif, à la différence de la tentative silencieuse du démarrage :
  /// sur un téléphone neuf, aucune autorisation n'a jamais été donnée, il faut
  /// bien la demander une fois.
  Future<void> _connectDrive() async {
    final l10n = context.l10n;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final drive = await DriveBackupTarget.connect(silent: false);
      if (drive == null) {
        _fail(l10n.restoreGoogleRefused);
        return;
      }
      final archives =
          (await drive.list()).where((a) => a.name.endsWith('.enc')).toList();
      if (archives.isEmpty) {
        // Distinguer « ce compte n'en contient pas » d'une panne : l'inscrit
        // s'est peut-être simplement trompé de compte Google.
        _fail(l10n.restoreGoogleEmpty);
        return;
      }
      if (!mounted) return;
      setState(() => _picked = drive);
      await _restore();
    } catch (_) {
      _fail(l10n.restoreFailedMessage);
    }
  }

  /// Laisse l'inscrit désigner son fichier de sauvegarde.
  ///
  /// Nécessaire après une réinstallation : la copie de `Download` est toujours
  /// là physiquement, mais l'application n'en a plus l'attribution et ne peut
  /// donc pas la lister toute seule.
  Future<void> _pickFile() async {
    final l10n = context.l10n;
    try {
      final picked = await FilePicker.platform.pickFiles(withData: false);
      final path = picked?.files.single.path;
      if (path == null) {
        _fail(l10n.restorePickCancelled);
        return;
      }
      // Vérifié tout de suite : désigner une photo par erreur doit donner un
      // message clair, pas un échec de déchiffrement quinze secondes plus tard.
      final head = await File(path).openRead(0, 4).first;
      if (String.fromCharCodes(head) != kBackupMagic) {
        _fail(l10n.restorePickWrongFile);
        return;
      }
      if (!mounted) return;
      setState(() {
        _picked = PickedArchiveTarget(File(path));
        _error = null;
      });
      await _restore();
    } catch (_) {
      _fail(l10n.restoreFailedMessage);
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _running = false;
      _error = message;
    });
  }

  Future<void> _applyPrefs(Map<String, Object> prefs) async {
    final store = await SharedPreferences.getInstance();
    for (final entry in prefs.entries) {
      final value = entry.value;
      if (value is String) {
        await store.setString(entry.key, value);
      } else if (value is bool) {
        await store.setBool(entry.key, value);
      } else if (value is int) {
        await store.setInt(entry.key, value);
      } else if (value is double) {
        await store.setDouble(entry.key, value);
      } else if (value is List<String>) {
        await store.setStringList(entry.key, value);
      }
    }
  }

  Future<void> _skip() async {
    await _state.setStage(RestoreStage.skipped);
    if (mounted) widget.onSkip();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final a = widget.announcement;

    return PopScope(
      // Sortir par le bouton Retour laisserait l'application dans un état
      // ambigu : le choix doit être explicite, et « Ignorer » est toujours là.
      canPop: false,
      child: Scaffold(
        backgroundColor: context.semantic.surfaceMuted,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.settings_backup_restore,
                  size: 48,
                  color: context.colors.primary,
                ),
                AppSpacing.vGapLg,
                Text(l10n.restoreTitle, style: context.text.headlineSmall),
                AppSpacing.vGapMd,
                Text(
                  l10n.restoreFound(
                    _formatDate(a.lastAt),
                    formatBytes(a.bytes, l10n),
                  ),
                  style: context.text.bodyMedium,
                ),
                AppSpacing.vGapSm,
                // Dit franchement ce qui ne reviendra pas. Le découvrir après
                // coup serait bien pire que de le lire maintenant.
                Text(
                  l10n.restoreExplain,
                  style: context.text.bodySmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
                if (a.accountHint != null) ...[
                  AppSpacing.vGapSm,
                  Text(
                    a.accountHint!,
                    style: context.text.labelMedium
                        ?.copyWith(color: context.colors.primary),
                  ),
                ],
                if (_error != null) ...[
                  AppSpacing.vGapLg,
                  Text(
                    _error!,
                    style: context.text.bodySmall
                        ?.copyWith(color: context.colors.error),
                  ),
                ],
                AppSpacing.vGapXl,
                if (_staged)
                  ..._readyToRestart(l10n)
                else ...[
                  if (_running) ...[
                    const LinearProgressIndicator(),
                    AppSpacing.vGapSm,
                    Text(l10n.restoreRunning, style: context.text.bodySmall),
                  ] else
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _restore,
                        child: Text(l10n.restoreAction),
                      ),
                    ),
                  AppSpacing.vGapSm,
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.cloud_outlined, size: 18),
                      label: Text(l10n.restoreConnectGoogle),
                      onPressed: _running ? null : _connectDrive,
                    ),
                  ),
                  AppSpacing.vGapXs,
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: _running ? null : _pickFile,
                      child: Text(l10n.restorePickFile),
                    ),
                  ),
                  AppSpacing.vGapXs,
                  Text(
                    l10n.restorePickHint,
                    style: context.text.labelSmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                  AppSpacing.vGapSm,
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      // Toujours disponible, y compris pendant l'opération :
                      // c'est la porte de sortie.
                      onPressed: _running ? null : _skip,
                      child: Text(l10n.restoreSkip),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// La base restaurée est posée à côté ; l'échange aura lieu au prochain
  /// démarrage, avant que quoi que ce soit n'ouvre le fichier.
  ///
  /// On demande donc à l'inscrit de rouvrir l'application, franchement, plutôt
  /// que de la relancer dans son dos — un redémarrage silencieux au milieu
  /// d'une restauration inquiéterait plus qu'il ne rassurerait.
  List<Widget> _readyToRestart(AppLocalizations l10n) => [
        Text(l10n.restoreDoneRestart, style: context.text.bodyMedium),
        AppSpacing.vGapLg,
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _quit,
            child: Text(l10n.restoreCloseApp),
          ),
        ),
      ];

  /// Termine réellement le processus.
  ///
  /// **`SystemNavigator.pop()` ne suffit pas.** Sur Android, il termine
  /// l'activité mais laisse le processus vivant : à la réouverture, le système
  /// reprend l'existant, `main()` ne s'exécute pas, l'échange du fichier
  /// restauré n'a jamais lieu — et l'inscrit retombe sur cet écran, indéfiniment.
  ///
  /// Or c'est précisément un démarrage complet qu'il nous faut : la base ne peut
  /// être remplacée qu'avant que quoi que ce soit ne l'ouvre. `exit(0)` tue le
  /// processus, ce qui garantit que le lancement suivant repartira de `main()`.
  Future<void> _quit() async {
    if (Platform.isAndroid || Platform.isLinux) {
      exit(0);
    }
    // iOS interdit qu'une application se termine d'elle-même : on retombe sur
    // la sortie douce, et l'inscrit fermera l'application à la main.
    await SystemNavigator.pop();
  }

  static String _formatDate(DateTime at) {
    final d = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:'
        '${two(d.minute)}';
  }
}
