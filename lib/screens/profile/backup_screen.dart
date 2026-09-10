import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/backup/backup_schedule.dart';
import '../../core/services/backup/backup_runner.dart';
import '../../core/services/backup/backup_service.dart';
import '../../core/services/backup/backup_settings_store.dart';
import '../../core/services/backup/server_backup_key_provider.dart';
import '../../core/services/backup/backup_snapshot.dart';
import '../../core/services/backup/backup_target.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/byte_format.dart';
import '../../l10n/app_localizations.dart';
import 'restore_screen.dart';
import '../../core/services/backup/drive_backup_target.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/connectivity_provider.dart';
import '../../talky_api_client.dart';

/// Réglages de sauvegarde : fréquence, état, sauvegarde manuelle.
///
/// ── Ce que cet écran dit, et pourquoi il le dit ──
///
/// Deux phrases y sont obligatoires, et ce ne sont pas des mentions légales
/// reléguées ailleurs :
///
/// - **Ce qui n'est pas sauvegardé.** Les médias n'y sont pas. Un inscrit qui
///   croit ses photos à l'abri parce qu'il voit « sauvegarde quotidienne »
///   découvrirait le contraire au pire moment. L'écran renvoie donc vers
///   « Exporter cette période ».
/// - **Que le chiffrement n'est pas de bout en bout.** La clé étant dérivée
///   côté serveur, Alanya peut techniquement déchiffrer. Le taire serait une
///   faute.
class BackupScreen extends StatefulWidget {
  /// Fournisseur de clés. Laissé nul, l'écran interroge le serveur ; les tests
  /// en passent un factice, sans réseau.
  final BackupKeyProvider? keys;

  /// Destination. Aujourd'hui le stockage de l'appareil ; Drive viendra
  /// derrière la même interface.
  final BackupTarget? target;

  const BackupScreen({super.key, this.keys, this.target});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  static const _store = BackupSettingsStore();
  static const _policy = BackupSchedulePolicy();

  late final BackupKeyProvider _keys = widget.keys ??
      ServerBackupKeyProvider((path) async {
        final api = context.read<TalkyApiClient>();
        final kid = path.startsWith('/backup/key/')
            ? int.tryParse(path.substring('/backup/key/'.length))
            : null;
        return jsonEncode(await api.fetchBackupKey(kid: kid));
      });

  BackupFrequency _frequency = BackupFrequency.weekly;
  BackupDestination _destination = BackupDestination.device;
  BackupState _state = const BackupState();
  BackupMeta? _meta;
  bool _loading = true;
  bool _running = false;

  /// Adresse du compte Alanya. Sert à retrouver le compte Google déjà autorisé
  /// lors des sauvegardes silencieuses, rien de plus : elle n'ouvre aucun droit
  /// sur le Drive de qui que ce soit.
  String? _accountEmail;

  /// Compte Google réellement connecté, qui peut très bien ne pas être celui
  /// du compte Alanya — et c'est légitime.
  String? _connectedAccount;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<BackupTarget> _resolveTarget() async {
    final provided = widget.target;
    if (provided != null) return provided;
    // Lecture seule : afficher un descriptif, lister des archives. L'écriture
    // passe par `BackupRunner.runNow`, qui sait distinguer le dépôt voulu du
    // pis-aller — distinction que cet écran ne doit surtout pas refaire dans
    // son coin, sous peine de diverger de la sauvegarde automatique.
    return BackupRunner.readTarget(accountEmail: _accountEmail);
  }

  Future<void> _load() async {
    // Lu avant tout `await` : après, le contexte peut ne plus être valable.
    final chat = context.read<ChatProvider>();
    _accountEmail = context.read<AuthProvider>().currentUser?.email;
    final frequency = await _store.frequency();
    final destination = await _store.destination();
    final state = await _store.state();
    BackupMeta? meta;
    String? connected;
    try {
      final target = await _resolveTarget();
      // Le compte réellement connecté, et non celui qu'on suppose : afficher
      // l'adresse du compte Alanya alors que les sauvegardes partent sur un
      // autre Drive serait exactement le genre de mensonge tranquille qu'on
      // vient de corriger ailleurs.
      if (target is DriveBackupTarget) connected = target.accountEmail;
      meta = await BackupService(db: chat.repository.dao.db, keys: _keys)
          .readMeta(target, chat.repository.myId);
    } catch (_) {
      // Un descriptif illisible ou une destination indisponible ne doit pas
      // empêcher l'écran de s'afficher : le reste des réglages reste utile.
      meta = null;
    }
    if (!mounted) return;
    setState(() {
      _frequency = frequency;
      _destination = destination;
      _connectedAccount = connected;
      _state = state;
      _meta = meta;
      _loading = false;
    });
  }

  Future<void> _setFrequency(BackupFrequency value) async {
    setState(() => _frequency = value);
    await _store.setFrequency(value);
  }

  Future<void> _runNow() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final chat = context.read<ChatProvider>();
    final api = context.read<TalkyApiClient>();
    final connectivity = context.read<ConnectivityProvider>().service;
    setState(() => _running = true);

    final attempt = await BackupRunner(
      db: chat.repository.dao.db,
      keys: _keys,
      connectivity: connectivity,
      accountEmail: _accountEmail,
      target: widget.target,
      // Sans cette déclaration, l'écran de restauration d'un futur téléphone
      // ne saurait pas qu'une sauvegarde existe — et devrait réclamer un
      // compte Google à l'aveugle au tout premier démarrage.
      onSucceeded: (meta) => api.publishBackupMeta(
        bytes: meta.bytes,
        kid: meta.kid,
        messageCount: meta.messageCount,
      ),
    ).runNow(alanyaID: chat.repository.myId);

    if (!mounted) return;
    setState(() {
      _running = false;
      _state = attempt.state;
      if (attempt.meta != null) _meta = attempt.meta;
    });
    messenger.showSnackBar(SnackBar(
      content: Text(switch (attempt.result) {
        BackupRunResult.success => l10n.backupSucceeded,
        // Dit franchement ce qui s'est passé. Annoncer « réussie » parce qu'un
        // fichier a été écrit quelque part est précisément ce qui laissait
        // croire à des données à l'abri chez Google alors qu'elles étaient sur
        // le téléphone.
        BackupRunResult.fallback => l10n.backupFellBack,
        BackupRunResult.failure => l10n.backupFailed,
      }),
    ));
  }

  /// Demande l'autorisation Google, **sur un appui explicite**.
  ///
  /// C'est le seul endroit qui la demande, et c'est délibéré : la sauvegarde
  /// automatique part d'un rappel de cycle de vie, sans interaction en cours.
  /// Y faire surgir un sélecteur de compte Google, sans que personne n'ait rien
  /// demandé, serait au mieux déroutant et au pire refusé par réflexe.
  ///
  /// [change] sert quand un compte est déjà connecté : sans oublier le choix
  /// local au préalable, `signIn()` reconnecterait le même compte sans rien
  /// demander, et le bouton « changer de compte » ne changerait rien.
  Future<void> _connectDrive({bool change = false}) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _running = true);
    if (change) await DriveBackupTarget.forgetAccount();
    // Aucune pré-sélection : le sélecteur Google doit s'ouvrir et lister tous
    // les comptes de l'appareil. C'est l'inscrit qui choisit son Drive, pas
    // l'adresse qu'il a donnée à Alanya.
    final drive = await DriveBackupTarget.connect(silent: false);
    if (!mounted) return;
    setState(() => _running = false);

    if (drive == null) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.backupDriveRefused)));
      // Un changement annulé a effacé le choix local : le rétablir en silence,
      // sinon les sauvegardes suivantes retomberaient en secours sans raison.
      if (change) {
        unawaited(DriveBackupTarget.connect(accountEmail: _accountEmail));
      }
      return;
    }
    _connectedAccount = drive.accountEmail;
    await _store.setDestination(BackupDestination.drive);
    if (!mounted) return;
    setState(() => _destination = BackupDestination.drive);
    messenger
        .showSnackBar(SnackBar(content: Text(l10n.backupDriveConnected)));
    // Relu : le descriptif affiché vient désormais d'un autre endroit.
    await _load();
  }

  Future<void> _useDeviceStorage() async {
    await _store.setDestination(BackupDestination.device);
    if (!mounted) return;
    setState(() => _destination = BackupDestination.device);
    await _load();
  }

  /// Explique ce qu'une sauvegarde locale protège, et ce qu'elle ne protège
  /// pas.
  ///
  /// Le même texte sert dans les deux cas — secours subi ou local choisi. Dans
  /// le second, il informe sans alarmer : quelqu'un qui ne veut pas de compte
  /// Google a le droit de savoir exactement où il en est, sans être relancé.
  Future<void> _showLocalRisks() async {
    final l10n = context.l10n;
    final connect = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.backupLocalRisksTitle),
        content: Text(l10n.backupLocalRisksBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonClose),
          ),
          if (_destination != BackupDestination.drive)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.backupConnectDrive),
            ),
        ],
      ),
    );
    if (connect == true && mounted) await _connectDrive();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: context.semantic.surfaceMuted,
      appBar: AppBar(title: Text(l10n.backupTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              children: [
                if (_running) const LinearProgressIndicator(minHeight: 2),
                _statusCard(l10n),
                _destinationCard(l10n),
                _restoreCard(l10n),
                _frequencyCard(l10n),
                _noticeCard(l10n),
              ],
            ),
    );
  }

  Widget _statusCard(AppLocalizations l10n) {
    final meta = _meta;
    final stale = _policy.shouldAlert(
      now: DateTime.now().toUtc(),
      frequency: _frequency,
      state: _state,
    );

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.backupSubtitle, style: context.text.titleSmall),
          AppSpacing.vGapSm,
          Text(
            meta == null
                ? l10n.backupLastNever
                : l10n.backupLastAt(
                    _formatDate(meta.createdAt),
                    formatBytes(meta.bytes, l10n),
                  ),
            style: context.text.bodySmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          if (meta != null) ...[
            const SizedBox(height: 2),
            Text(
              l10n.backupCounts(meta.messageCount, meta.conversationCount),
              style: context.text.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
          if (stale) ...[
            AppSpacing.vGapMd,
            // Signalé seulement après plusieurs jours sans succès : alerter à
            // chaque coupure réseau apprendrait à l'ignorer, y compris le jour
            // où ça compte.
            _warning(l10n.backupStaleWarning),
          ],
          AppSpacing.vGapMd,
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.backup_outlined, size: 18),
              label: Text(_running ? l10n.backupRunning : l10n.backupRunNow),
              onPressed: _running ? null : _runNow,
            ),
          ),
        ],
      ),
    );
  }

  /// Dit **où** vont les données, et permet d'en changer.
  ///
  /// Son absence est ce qui rendait la question « ma sauvegarde n'est-elle pas
  /// censée être sur le Drive ? » impossible à trancher depuis l'application :
  /// l'écran affichait un état sans jamais nommer la destination.
  Widget _destinationCard(AppLocalizations l10n) {
    final onDrive = _destination == BackupDestination.drive;
    final fallback = _state.lastFallbackAt;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.backupDestinationLabel,
                  style: context.text.titleSmall,
                ),
              ),
              // Le ⓘ reste disponible dans les deux cas : comprendre ce que
              // protège une sauvegarde locale intéresse autant celui qui la
              // subit que celui qui la choisit.
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.info_outline, size: 20),
                tooltip: l10n.backupLocalRisksTitle,
                onPressed: _showLocalRisks,
              ),
            ],
          ),
          Text(
            !onDrive
                ? l10n.backupDestinationDevice
                // Drive choisi mais aucun compte connecté sur CET appareil :
                // le cas normal après une migration, puisque le choix voyage
                // dans la sauvegarde alors que l'autorisation Google, elle,
                // reste attachée à l'appareil. Afficher une adresse ici
                // laisserait croire à un lien qui n'existe pas.
                : _connectedAccount == null
                    ? l10n.backupDestinationDriveUnlinked
                    : l10n.backupDestinationDrive(_accountHint()),
            style: context.text.bodyMedium,
          ),
          // N'apparaît que si Drive a VRAIMENT été visé. Sur un compte où
          // personne n'a jamais connecté Google, rien n'a échoué : il n'y a
          // donc rien à signaler, et personne à relancer.
          if (onDrive && fallback != null) ...[
            AppSpacing.vGapMd,
            _warning(l10n.backupFellBackAt(_formatDate(fallback))),
          ],
          AppSpacing.vGapMd,
          if (onDrive) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.switch_account_outlined, size: 18),
                label: Text(l10n.backupChangeAccount),
                onPressed:
                    _running ? null : () => _connectDrive(change: true),
              ),
            ),
            AppSpacing.vGapXs,
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                icon: const Icon(Icons.phone_android, size: 18),
                label: Text(l10n.backupUseDevice),
                onPressed: _running ? null : _useDeviceStorage,
              ),
            ),
          ] else
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.cloud_outlined, size: 18),
                label: Text(l10n.backupConnectDrive),
                onPressed: _running ? null : () => _connectDrive(),
              ),
            ),
        ],
      ),
    );
  }

  /// Adresse masquée, jamais en clair : elle n'a pas à traîner à l'écran ni
  /// dans une capture partagée au support.
  ///
  /// Le compte réellement connecté prime sur celui du compte Alanya : ce sont
  /// deux choses différentes, et c'est la première qui dit où vont les données.
  String _accountHint() {
    final email = (_connectedAccount ?? _accountEmail ?? '').trim();
    final at = email.indexOf('@');
    if (at < 1) return '';
    return '${email[0]}•••${email.substring(at)}';
  }

  /// Accès à la restauration, **toujours disponible**.
  ///
  /// L'annonce du serveur au démarrage sert à *proposer* la restauration au bon
  /// moment, pas à l'*autoriser*. Sans cette entrée, la porte de secours
  /// — « choisir un fichier » — se retrouvait derrière la porte qu'elle est
  /// censée contourner : serveur indisponible, sauvegarde antérieure à la
  /// métadonnée, ou archive rapatriée depuis un ordinateur, et l'inscrit avait
  /// sa sauvegarde sous les yeux sans aucun moyen de l'utiliser.
  Widget _restoreCard(AppLocalizations l10n) => _card(
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.settings_backup_restore),
          title: Text(l10n.backupRestoreEntry),
          subtitle: Text(
            l10n.backupRestoreEntryHint,
            style: context.text.labelSmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _openRestore,
        ),
      );

  Future<void> _openRestore() async {
    final chat = context.read<ChatProvider>();
    final navigator = Navigator.of(context);
    final target = await _resolveTarget();
    if (!mounted) return;

    await navigator.push(MaterialPageRoute(
      builder: (_) => RestoreScreen(
        db: chat.repository.dao.db,
        keys: _keys,
        target: target,
        // Aucune annonce serveur ici : c'est tout l'intérêt de cette entrée.
        // L'écran affichera les boutons Drive et « choisir un fichier », et
        // l'inscrit désignera lui-même ce qu'il veut restaurer.
        announcement: BackupAnnouncement(
          lastAt: _meta?.createdAt ?? DateTime.now(),
          bytes: _meta?.bytes ?? 0,
          messageCount: _meta?.messageCount,
        ),
        onSkip: () => navigator.pop(),
      ),
    ));
  }

  Widget _frequencyCard(AppLocalizations l10n) => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.backupFrequencyLabel, style: context.text.titleSmall),
            AppSpacing.vGapSm,
            RadioGroup<BackupFrequency>(
              groupValue: _frequency,
              onChanged: (v) => v == null ? null : _setFrequency(v),
              child: Column(
                children: BackupFrequency.values
                    .map((f) => RadioListTile<BackupFrequency>(
                          value: f,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(_frequencyLabel(f, l10n)),
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      );

  Widget _noticeCard(AppLocalizations l10n) => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Un inscrit qui croit ses photos à l'abri parce qu'il voit
            // « sauvegarde quotidienne » le découvrirait au pire moment.
            Text(
              l10n.backupWhatIsSaved,
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            AppSpacing.vGapSm,
            Text(
              l10n.backupNotEndToEnd,
              style: context.text.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ),
      );

  /// Carte de l'écran.
  ///
  /// **`Material` et non `Container`.** Un `ListTile` peint son fond et ses
  /// ondes de clic sur le `Material` le plus proche ; posé dans un conteneur
  /// qui porte lui-même une couleur, il déclenche une assertion et se retrouve
  /// remplacé par un bloc d'erreur en mode debug. Toute la carte devenait
  /// inutilisable.
  Widget _card({required Widget child}) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        child: Material(
          color: context.colors.surface,
          borderRadius: AppRadius.brMd,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: child,
          ),
        ),
      );

  Widget _warning(String text) => Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: context.colors.errorContainer,
          borderRadius: AppRadius.brSm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 18, color: context.colors.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: context.text.bodySmall
                    ?.copyWith(color: context.colors.onErrorContainer),
              ),
            ),
          ],
        ),
      );

  String _frequencyLabel(BackupFrequency f, AppLocalizations l10n) =>
      switch (f) {
        BackupFrequency.daily => l10n.backupFrequencyDaily,
        BackupFrequency.weekly => l10n.backupFrequencyWeekly,
        BackupFrequency.monthly => l10n.backupFrequencyMonthly,
        BackupFrequency.never => l10n.backupFrequencyNever,
      };

  static String _formatDate(DateTime at) {
    final d = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:'
        '${two(d.minute)}';
  }
}
