import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/media_cache_service.dart';
import '../../core/services/storage_info_service.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/backend_url.dart';
import '../../core/utils/byte_format.dart';
import '../../core/utils/forward_message.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/chat_provider.dart';
import '../../talky_api_client.dart';
import '../../talky_models.dart';
import '../../widgets/video_message_preview.dart';
import '../chats/forward_message_screen.dart';
import '../chats/media_viewer_screen.dart';

/// Ordre de la grille. `wire` est la valeur attendue par `GET /auth/me/media`.
enum _MediaSort {
  recent('recent'),
  largest('size');

  const _MediaSort(this.wire);
  final String wire;
}

/// Origine des médias affichés.
enum _MediaOwner {
  received('received'),
  sent('sent'),
  all('all');

  const _MediaOwner(this.wire);
  final String wire;
}

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

/// Grille paginée des médias de l'utilisateur, doublée d'un outil de gestion
/// du stockage : origine, poids et date de chaque élément, tri par taille, et
/// sélection multiple pour libérer de la place ou transférer.
///
/// Les médias **reçus** sont affichés par défaut : ce sont eux que le
/// téléchargement automatique met en cache, donc eux qui occupent l'appareil.
class MyMediaScreen extends StatefulWidget {
  const MyMediaScreen({super.key});

  @override
  State<MyMediaScreen> createState() => _MyMediaScreenState();
}

class _MyMediaScreenState extends State<MyMediaScreen> {
  final _items = <MyMediaItem>[];
  final _scrollController = ScrollController();

  /// msgID des éléments cochés. Vide = mode consultation.
  final _selected = <int>{};

  _MediaSort _sort = _MediaSort.recent;
  _MediaOwner _owner = _MediaOwner.received;
  String? _nextCursor;
  bool _loading = false;
  bool _initial = true;
  bool _working = false;
  String? _error;

  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
    _scrollController.addListener(_onScroll);
    // Le compteur d'espace en tête vient du même service que l'écran
    // Paramètres › Stockage, pour que les deux affichent la même valeur.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<StorageInfoService>().refresh();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loading || _nextCursor == null) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _load();
    }
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading) return;
    if (!refresh && _nextCursor == null && !_initial) return;

    setState(() {
      _loading = true;
      if (refresh) _error = null;
    });

    try {
      final page = await context.read<TalkyApiClient>().getMyMedia(
            cursor: refresh ? null : _nextCursor,
            sort: _sort.wire,
            owner: _owner.wire,
          );
      if (!mounted) return;
      setState(() {
        if (refresh) {
          _items
            ..clear()
            ..addAll(page.items);
          // Une sélection portant sur des éléments qui ne sont plus chargés
          // n'aurait plus de sens : on repart propre.
          _selected.clear();
        } else {
          _items.addAll(page.items);
        }
        _nextCursor = page.nextCursor;
        _initial = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _initial = false;
        _error = '$e';
      });
    }
  }

  Future<void> _reload() async {
    setState(() {
      _nextCursor = null;
      _initial = true;
    });
    await _load(refresh: true);
  }

  Future<void> _changeSort(_MediaSort sort) async {
    if (sort == _sort || _loading) return;
    setState(() => _sort = sort);
    await _reload();
  }

  Future<void> _changeOwner(_MediaOwner owner) async {
    if (owner == _owner || _loading) return;
    setState(() => _owner = owner);
    await _reload();
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

  /// Supprime la copie locale des médias cochés. Le fichier reste sur le
  /// serveur et se retéléchargera à l'ouverture : la grille ne change pas.
  Future<void> _freeSpace() async {
    final l10n = context.l10n;
    final targets = _selectedItems;
    if (targets.isEmpty) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.myMediaFreeSpace),
        content: Text(l10n.myMediaFreeSpaceConfirm),
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
        // Le chemin local pointait sur le fichier qu'on vient d'effacer : le
        // laisser en base ferait échouer l'ouverture de la bulle.
        await dao.clearLocalMediaPath(item.msgID);
      }
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
    if (_initial && _loading) {
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
      onRefresh: () => _load(refresh: true),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.only(bottom: AppSpacing.lg),
        itemCount: groups.length + (_loading ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= groups.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
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

  /// Aperçu seul, sans habillage : la vidéo s'appuie sur `mediaThumb` (aucun
  /// fichier local ici, les médias viennent du serveur), l'image sur son URL.
  Widget _preview(MyMediaItem item) {
    final fallback = context.semantic.surfaceMuted;
    if (item.isVideo) {
      return VideoMessagePreview(
        thumbBase64: item.mediaThumb,
        durationSeconds: item.mediaDuration,
        borderRadius: BorderRadius.zero,
        expandToFill: true,
        playIconSize: 26,
        fallbackColor: fallback,
      );
    }

    final url = normalizeBackendUrl(item.mediaUrl) ?? '';
    if (url.isEmpty) {
      return Container(
        color: context.semantic.brandContainer,
        child: Icon(Icons.image_outlined, color: context.colors.primary),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      placeholder: (_, __) => Container(color: fallback),
      errorWidget: (_, __, ___) => Container(
        color: context.semantic.brandContainer,
        child: Icon(
          Icons.broken_image_outlined,
          color: context.colors.onSurfaceVariant,
        ),
      ),
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
