import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Cache réseau dédié à la grille « Mes médias ».
///
/// Le gestionnaire par défaut de flutter_cache_manager plafonne le nombre
/// d'objets conservés à 200 (`CacheConfig.maxNrOfCacheObjects`) : dès qu'on
/// scrolle au-delà de quelques pages, les vignettes déjà téléchargées sont
/// évincées (LRU) et doivent être re-téléchargées en remontant. Ce cache
/// partagé reçoit aussi les avatars et les autres écrans, ce qui accélère
/// encore les évictions.
///
/// Un cache dédié, avec un plafond d'objets élevé et une durée de vie longue,
/// permet à la grille de conserver ses images (les fichiers serveur étant
/// immuables, voir les en-têtes `Cache-Control: immutable` sur /uploads).
class MediaGridCache {
  MediaGridCache._();

  static CacheManager? _instance;

  static CacheManager get instance => _instance ??= CacheManager(
        Config(
          'mediaGridCache',
          maxNrOfCacheObjects: 3000,
          maxAge: const Duration(days: 60),
          stalePeriod: const Duration(days: 30),
        ),
      );
}
