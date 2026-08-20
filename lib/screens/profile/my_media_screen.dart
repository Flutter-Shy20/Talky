import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/db/chat_dao.dart';
import '../../core/services/media_cache_service.dart';
import '../../core/services/storage_info_service.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/backend_url.dart';
import '../../core/utils/byte_format.dart';
import '../../core/utils/forward_message.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/chat_provider.dart';
import '../../talky_models.dart';
import '../../widgets/video_message_preview.dart';
import '../chats/forward_message_screen.dart';
import '../chats/media_viewer_screen.dart';

/// Miroir, pour l'avertissement de suppression uniquement, de
/// `MEDIA_RETENTION_DAYS` côté serveur (`mediaRetentionPolicy.js`, défaut 30
/// jours). Purement indicatif : la vraie valeur est réglable par variable
/// d'environnement serveur et le client ne peut pas la connaître avec
/// certitude — ça sert juste à distinguer « sûrement encore sur le serveur »
/// de « peut-être déjà purgé », pour affiner le texte de confirmation.
const _kMediaRetentionDaysHeuristic = 30;

/// Ordre d'affichage de la grille.
enum _MediaSort { recent, largest }

/// Origine des médias affichés.
enum _MediaOwner { received, sent, all }

/// Une journée de médias, ou la totalité quand le tri par poids rend les dates
/// sans objet. [offset] est l'indice du premier élément dans la liste complète,
/// dont la visionneuse a besoin.
class _MediaGroup {
  final String? label;
  final List<MyMediaItem> items;
  final int offset;

  const _MediaGroup({
    required this.label,
    required this.items,
    required this.offset,
  });
}

/// Grille des médias **réellement présents sur l'appareil**, doublée d'un
/// outil de gestion du stockage : origine, poids et date de chaque élément,
/// tri par taille, et sélection multiple pour libérer de la place ou
/// transférer.
///
/// Source de vérité : la base locale (Drift), pas le serveur — un média reçu
/// mais jamais téléchargé (auto-téléchargement désactivé, échec de
/// téléchargement…) n'apparaît jamais ici, seulement une fois
/// `localMediaPath` renseigné, que ce soit via le téléchargement automatique
/// ou manuel. Ça fonctionne donc entièrement hors connexion.
class MyMediaScreen extends StatefulWidget {
  const MyMediaScreen({super.key});

  @override
  State<MyMediaScreen> createState() => _MyMediaScreenState();
}

class _MyMediaScreenState extends State<MyMediaScreen> {
  final _items = <MyMediaItem>[];

  /// msgID des éléments cochés. Vide = mode consultation.
  final _selected = <int>{};

  _MediaSort _sort = _MediaSort.recent;

  /// Tous par défaut : « Mes médias » doit contenir tous les médias de
  /// l'utilisateur (envoyés comme reçus). Les pastilles Reçus/Envoyés
  /// permettent de resserrer le périmètre.
  _MediaOwner _owner = _MediaOwner.all;

  StreamSubscription<List<LocalMediaRow>>? _sub;
  bool _initial = true;
  bool _working = false;
  String? _error;

  /// Octets décodés des vignettes base64, par msgID. Évite de re-décoder à
  /// chaque build (Image.memory est keyé sur l'identité des octets) et borne
  /// la mémoire (~15 Ko par vignette).
  final _thumbBytes = <int, Uint8List>{};

  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _subscribe();
    // Le compteur d'espace en tête vient du même service que l'écran
    // Paramètres › Stockage, pour que les deux affichent la même valeur.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<StorageInfoService>().refresh();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// (Ré)abonnement à la base locale selon le filtre d'origine courant.
  /// Appelé à l'ouverture et à chaque changement de pastille Reçus/Envoyés :
  /// le tri par poids, lui, se fait en mémoire (voir [_onRows]), inutile de
  /// se réabonner pour ça.
  void _subscribe() {
    _sub?.cancel();
    _thumbBytes.clear();
    final dao = context.read<ChatProvider>().repository.dao;
    final myId = context.read<ChatProvider>().repository.myId;
    bool? mineOnly;
    if (_owner == _MediaOwner.sent) mineOnly = true;
    if (_owner == _MediaOwner.received) mineOnly = false;
    setState(() {
      _initial = true;
      _error = null;
    });
    _sub = dao.watchLocalMedia(myId, mineOnly: mineOnly).listen(
      _onRows,
      onError: (e) {
        if (!mounted) return;
        setState(() {
          _initial = false;
          _error = '$e';
        });
      },
    );
  }

  /// Convertit les lignes locales en [MyMediaItem] pour l'affichage, en
  /// vérifiant au passage que le fichier annoncé existe encore réellement sur
  /// le disque — la base peut mentir si le fichier a été effacé hors de
  /// l'app (nettoyage du système, gestionnaire de fichiers…). Un fichier
  /// manquant est désynchronisé de la base plutôt que laissé à pointer dans
  /// le vide.
  void _onRows(List<LocalMediaRow> rows) {
    final dao = context.read<ChatProvider>().repository.dao;
    final myId = context.read<ChatProvider>().repository.myId;
    final items = <MyMediaItem>[];
    for (final row in rows) {
      final msg = row.message;
      final path = msg.localMediaPath;
      if (path == null || !File(path).existsSync()) {
        if (path != null) unawaited(dao.clearLocalMediaPath(msg.msgID));
        continue;
      }
      items.add(MyMediaItem(
        msgID: msg.msgID,
        conversationID: msg.conversationID,
        senderID: msg.senderID,
        isMine: msg.senderID == myId,
        senderName: row.senderName,
        type: msg.type,
        mediaUrl: msg.mediaUrl ?? '',
        mediaName: msg.mediaName,
        mediaThumb: msg.mediaThumb,
        mediaDuration: msg.mediaDuration,
        mediaSize: msg.mediaSize,
        sendAt: msg.sendAt,
        localMediaPath: path,
      ));
    }
    if (_sort == _MediaSort.largest) {
      items.sort((a, b) => (b.mediaSize ?? 0).compareTo(a.mediaSize ?? 0));
    }
    // Tri "récent" déjà assuré par l'ORDER BY sendAt DESC de la requête.

    if (!mounted) return;
    setState(() {
      _items
        ..clear()
        ..addAll(items);
      // Une sélection portant sur des éléments qui ne sont plus chargés
      // n'aurait plus de sens.
      _selected.removeWhere((id) => items.every((i) => i.msgID != id));
      _initial = false;
    });
  }

  /// Force une nouvelle vérification d'existence des fichiers (voir
  /// [_onRows]) : utile si des fichiers ont été effacés hors de l'app depuis
  /// le dernier passage, ce dont la base ne peut pas être informée toute
  /// seule.
  Future<void> _reload() async {
    _subscribe();
  }

  Future<void> _changeSort(_MediaSort sort) async {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    // Le jeu d'éléments ne change pas, seul l'ordre : pas besoin de
    // réabonnement, un tri en mémoire suffit à partir de la liste courante.
    final current = List<MyMediaItem>.from(_items);
    if (sort == _MediaSort.largest) {
      current.sort((a, b) => (b.mediaSize ?? 0).compareTo(a.mediaSize ?? 0));
    } else {
      current.sort((a, b) => (b.sendAt ?? DateTime(0))
          .compareTo(a.sendAt ?? DateTime(0)));
    }
    setState(() {
      _items
        ..clear()
        ..addAll(current);
    });
  }

  Future<void> _changeOwner(_MediaOwner owner) async {
    if (owner == _owner) return;
    setState(() => _owner = owner);
    _subscribe();
  }

  // ── Regroupement ─────────────────────────────────────────────────────

  /// Une section par journée en tri chronologique. En tri par poids l'ordre
  /// n'est plus temporel : un en-tête de date y serait faux, on n'en met pas.
  List<_MediaGroup> _buildGroups() {
    if (_items.isEmpty) return const [];
    if (_sort == _MediaSort.largest) {
      return [_MediaGroup(label: null, items: _items, offset: 0)];
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    final groups = <_MediaGroup>[];
    var current = <MyMediaItem>[];
    String? currentLabel;
    var offset = 0;

    for (final item in _items) {
      final sentAt = item.sendAt;
      final label = sentAt == null ? '' : _dayLabel(sentAt, today, yesterday);
      if (current.isNotEmpty && currentLabel != label) {
        groups.add(_MediaGroup(
          label: currentLabel!.isEmpty ? null : currentLabel,
          items: current,
          offset: offset,
        ));
        offset += current.length;
        current = <MyMediaItem>[];
      }
      currentLabel = label;
      current.add(item);
    }
    if (current.isNotEmpty) {
      groups.add(_MediaGroup(
        label: (currentLabel ?? '').isEmpty ? null : currentLabel,
        items: current,
        offset: offset,
      ));
    }
    return groups;
  }

  String _dayLabel(DateTime at, DateTime today, DateTime yesterday) {
    final date = DateTime(at.year, at.month, at.day);
    if (date == today) return context.l10n.today;
    if (date == yesterday) return context.l10n.yesterday;
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  // ── Sélection ────────────────────────────────────────────────────────

  void _toggle(MyMediaItem item) {
    setState(() {
      if (!_selected.remove(item.msgID)) _selected.add(item.msgID);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  void _selectAll() =>
      setState(() => _selected.addAll(_items.map((i) => i.msgID)));

  List<MyMediaItem> get _selectedItems =>
      _items.where((i) => _selected.contains(i.msgID)).toList();

  // ── Actions ──────────────────────────────────────────────────────────

  /// Supprime la copie locale des médias cochés : ils disparaissent de « Mes
  /// médias » (qui ne liste que ce qui est téléchargé) et redeviennent, dans
  /// leur conversation, un média à retélécharger. Le message et le fichier
  /// distant ne sont pas touchés — sauf si le fichier distant a déjà été
  /// purgé côté serveur (rétention 30 jours), auquel cas cette suppression
  /// devient définitive : voir l'avertissement adapté ci-dessous.
  Future<void> _freeSpace() async {
    final l10n = context.l10n;
    final targets = _selectedItems;
    if (targets.isEmpty) return;

    final maybeGone = targets.any((i) =>
        i.sendAt != null &&
        DateTime.now().difference(i.sendAt!).inDays >
            _kMediaRetentionDaysHeuristic);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.myMediaFreeSpace),
        content: Text(maybeGone
            ? l10n.myMediaFreeSpaceConfirmMaybeGone
            : l10n.myMediaFreeSpaceConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _working = true);
    final cache = MediaCacheService();
    final dao = context.read<ChatProvider>().repository.dao;
    var freed = 0;
    for (final item in targets) {
      final bytes = await cache.removeForUrl(item.mediaUrl);
      if (bytes > 0) {
        freed += bytes;
      }
      // Le chemin local pointait sur le fichier qu'on vient d'effacer (ou
      // sur un fichier hors du cache géré par [MediaCacheService], selon
      // l'origine du téléchargement) : le laisser en base ferait échouer
      // l'ouverture de la bulle dans la conversation.
      await dao.clearLocalMediaPath(item.msgID);
    }
    if (!mounted) return;

    setState(() {
      _working = false;
      _selected.clear();
    });
    await context.read<StorageInfoService>().refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          freed > 0
              ? l10n.myMediaFreedSpace(formatBytes(freed, l10n))
              : l10n.myMediaNothingCached,
        ),
      ),
    );
  }

  Future<void> _forward() async {
    final l10n = context.l10n;
    final ids = _selectedItems.map((i) => i.msgID).toList();
    if (ids.isEmpty) return;

    setState(() => _working = true);
    final dao = context.read<ChatProvider>().repository.dao;
    final rows = await dao.messagesByIds(ids);
    if (!mounted) return;
    setState(() => _working = false);

    // Un média peut avoir quitté le cache local (historique masqué, purge) :
    // l'API le connaît encore, pas la base Drift dont le transfert dépend.
    final forwardable = rows.where(canForwardMessage).toList();
    if (forwardable.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.myMediaForwardUnavailable)),
      );
      return;
    }

    _clearSelection();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => forwardable.length == 1
            ? ForwardMessageScreen(message: forwardable.first)
            : ForwardMessageScreen(messages: forwardable),
      ),
    );
  }

  void _openViewer(int index) {
    final viewerItems = _items
        .map(
          (m) => MediaViewerItem(
            isVideo: m.isVideo,
            localPath: m.localMediaPath,
            networkUrl: normalizeBackendUrl(m.mediaUrl),
            title: m.mediaName,
            msgID: m.msgID,
          ),
        )
        .toList();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MediaViewerScreen(
          items: viewerItems,
          initialIndex: index,
        ),
      ),
    );
  }

  // ── Rendu ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopScope(
      // En mode sélection, Retour annule la sélection avant de quitter.
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _clearSelection();
      },
      child: Scaffold(
        backgroundColor: context.semantic.surfaceMuted,
        appBar: _selecting ? _selectionAppBar(l10n) : _browseAppBar(l10n),
        body: Column(
          children: [
            if (_working) const LinearProgressIndicator(minHeight: 2),
            _header(l10n),
            Expanded(child: _body(l10n)),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _browseAppBar(AppLocalizations l10n) =>
      AppBar(title: Text(l10n.myMediaTitle));

  PreferredSizeWidget _selectionAppBar(AppLocalizations l10n) => AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _clearSelection,
        ),
        title: Text(l10n.selectedCount(_selected.length)),
        actions: [
          IconButton(
            icon: const Icon(Icons.select_all),
            tooltip: l10n.myMediaSelectAll,
            onPressed: _working ? null : _selectAll,
          ),
          IconButton(
            icon: const Icon(Icons.forward),
            tooltip: l10n.forward,
            onPressed: _working ? null : _forward,
          ),
          IconButton(
            icon: const Icon(Icons.cleaning_services_outlined),
            tooltip: l10n.myMediaFreeSpace,
            onPressed: _working ? null : _freeSpace,
          ),
        ],
      );

  /// Espace occupé, origine et ordre : la page sert aussi à faire de la place.
  Widget _header(AppLocalizations l10n) {
    final cacheBytes =
        context.watch<StorageInfoService>().breakdown.mediaCacheBytes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.sd_storage_outlined,
                size: 18,
                color: context.colors.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.myMediaOnThisDevice(formatBytes(cacheBytes, l10n)),
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ),
              SegmentedButton<_MediaSort>(
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: _MediaSort.recent,
                    label: Text(l10n.myMediaSortRecent),
                  ),
                  ButtonSegment(
                    value: _MediaSort.largest,
                    label: Text(l10n.myMediaSortLargest),
                  ),
                ],
                selected: {_sort},
                onSelectionChanged: (s) => _changeSort(s.first),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _ownerChip(_MediaOwner.received, l10n.myMediaFilterReceived),
              _ownerChip(_MediaOwner.sent, l10n.myMediaFilterSent),
              _ownerChip(_MediaOwner.all, l10n.myMediaFilterAll),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ownerChip(_MediaOwner owner, String label) => ChoiceChip(
        label: Text(label),
        selected: _owner == owner,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => _changeOwner(owner),
      );

  Widget _body(AppLocalizations l10n) {
    if (_initial) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: AppSpacing.screenH,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.myMediaLoadFailed),
              AppSpacing.vGapMd,
              TextButton(
                onPressed: _reload,
                child: Text(l10n.commonRetry),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          l10n.myMediaEmpty,
          style: context.text.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      );
    }

    final groups = _buildGroups();
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: AppSpacing.lg),
        itemCount: groups.length,
        itemBuilder: (context, index) {
          final group = groups[index];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (group.label != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.sm,
                  ),
                  child: Text(
                    group.label!,
                    style: context.text.labelMedium?.copyWith(
                      color: context.colors.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 2),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 2,
                  mainAxisSpacing: 2,
                ),
                itemCount: group.items.length,
                itemBuilder: (context, i) =>
                    _cell(group.items[i], group.offset + i, l10n),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Octets décodés une seule fois par média (le décodage base64 est keyé
  /// sur l'identité des octets par le cache d'images de Flutter, un nouveau
  /// décodage à chaque build ré-enregistrerait une entrée).
  Uint8List _thumbBytesFor(int msgID, String base64) {
    var bytes = _thumbBytes[msgID];
    if (bytes == null) {
      // Borne mémoire (~15 Ko par vignette, 400 × 15 Ko ≈ 6 Mo au pire).
      if (_thumbBytes.length > 400) _thumbBytes.clear();
      bytes = base64Decode(base64);
      _thumbBytes[msgID] = bytes;
    }
    return bytes;
  }

  Widget _cell(MyMediaItem item, int globalIndex, AppLocalizations l10n) {
    final checked = _selected.contains(item.msgID);
    final sender = item.senderName;
    return GestureDetector(
      onTap: () => _selecting ? _toggle(item) : _openViewer(globalIndex),
      onLongPress: () => _toggle(item),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _preview(item),
          if (!item.isMine && sender != null && sender.isNotEmpty)
            _senderOverlay(l10n.myMediaFrom(sender)),
          if (item.mediaSize != null) _sizeOverlay(item.mediaSize!, l10n),
          if (_selecting) _selectionOverlay(checked),
        ],
      ),
    );
  }

  /// Aperçu seul, sans habillage. Le fichier est, par construction de
  /// [ChatDao.watchLocalMedia], toujours présent sur le disque — aucun appel
  /// réseau ici, ni pour l'image/vidéo elle-même ni pour sa vignette :
  /// `mediaThumb` (base64, en priorité, décodage bon marché pour une petite
  /// tuile de grille) ou à défaut le fichier local lui-même.
  Widget _preview(MyMediaItem item) {
    final fallback = context.semantic.surfaceMuted;
    if (item.isVideo) {
      return VideoMessagePreview(
        localPath: item.localMediaPath,
        thumbBase64: item.mediaThumb,
        durationSeconds: item.mediaDuration,
        borderRadius: BorderRadius.zero,
        expandToFill: true,
        playIconSize: 26,
        fallbackColor: fallback,
      );
    }

    final thumb = item.mediaThumb;
    if (thumb != null && thumb.isNotEmpty) {
      return Image.memory(
        _thumbBytesFor(item.msgID, thumb),
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }

    final path = item.localMediaPath;
    if (path != null) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: 480,
        errorBuilder: (_, __, ___) => Container(
          color: context.semantic.brandContainer,
          child: Icon(
            Icons.broken_image_outlined,
            color: context.colors.onSurfaceVariant,
          ),
        ),
      );
    }
    return Container(
      color: context.semantic.brandContainer,
      child: Icon(Icons.image_outlined, color: context.colors.primary),
    );
  }

  /// Expéditeur en haut, sur un média reçu : sans lui, une grille tous
  /// expéditeurs confondus ne dit pas d'où vient ce qu'on s'apprête à effacer.
  Widget _senderOverlay(String label) => Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 12),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black54, Colors.transparent],
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.labelSmall?.copyWith(color: Colors.white),
          ),
        ),
      );

  /// Poids en bas à gauche, sur un dégradé qui garantit le contraste quelle
  /// que soit l'image. À droite, `VideoMessagePreview` pose déjà sa durée.
  Widget _sizeOverlay(int bytes, AppLocalizations l10n) => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 12, 6, 4),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black54, Colors.transparent],
            ),
          ),
          child: Text(
            formatBytes(bytes, l10n),
            style: context.text.labelSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );

  Widget _selectionOverlay(bool checked) => Container(
        color: checked ? Colors.black38 : Colors.transparent,
        alignment: Alignment.topRight,
        padding: const EdgeInsets.all(4),
        child: Icon(
          checked ? Icons.check_circle : Icons.circle_outlined,
          size: 20,
          color: checked ? context.colors.primary : Colors.white70,
        ),
      );
}
