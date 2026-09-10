/// Ce qui, parmi les préférences locales, entre dans une sauvegarde.
///
/// ── Pourquoi une liste blanche, et jamais une liste noire ──
///
/// `SharedPreferences` est un fourre-tout : on y trouve la langue choisie à
/// côté de jetons de session, de chemins de fichiers locaux et de drapeaux
/// « on a déjà montré cet écran ». Une liste noire — « on prend tout sauf
/// ceci » — fait entrer par défaut dans la sauvegarde toute clé ajoutée plus
/// tard par quelqu'un qui n'aura pas lu ce fichier. Le jour où cette clé est
/// un jeton, on l'aura recopié sur un autre appareil sans le vouloir.
///
/// La liste blanche inverse le défaut : ce qui n'est pas classé ne part pas.
/// Le pire cas devient « une préférence n'est pas restaurée », qui se corrige
/// en trois secondes, au lieu de « un secret a fuité », qui ne se corrige pas.
///
/// ── Le garde-fou ──
///
/// Une liste blanche écrite une fois se périme en silence. Le test
/// `backup_prefs_policy_test.dart` balaie les sources et échoue quand une clé
/// apparaît sans avoir été classée : la décision est forcée, pas suggérée.
library;

/// Préférences de l'inscrit, à restaurer sur un nouvel appareil.
///
/// Le critère : est-ce un choix qu'il a fait, et qu'il serait agacé de devoir
/// refaire ?
const Set<String> kBackedUpKeys = {
  'app_locale',
  'theme_mode',
  'auto_download_media',
  'media_wifi_only',
  'media_data_saver',
  'media_visibility',
  'translation_auto',
  'translation_target',
  'hidden_calls_v1',
  'hidden_conv_at_v1',
  // Un choix de l'inscrit : lui redemander sa fréquence de sauvegarde sur son
  // nouveau téléphone serait exactement le genre de friction qu'on évite.
  'backup_frequency',
  // Même raisonnement : quelqu'un qui a choisi Drive le veut aussi sur son
  // nouveau téléphone. L'autorisation Google, elle, ne voyage pas — la
  // première sauvegarde y retombera donc en secours, avec le bandeau qui dit
  // exactement quoi faire. C'est cohérent et ça se lit tout seul.
  'backup_destination',
};

/// Propres à cet appareil-ci. Les restaurer serait au mieux inutile, au pire
/// nuisible — un chemin de fichier qui n'existe pas sur le nouveau téléphone,
/// un jeton qui n'a rien à voyager, un fait serveur qui se réapprendra seul.
const Set<String> kDeviceLocalKeys = {
  // Chemins et fichiers locaux : ils ne veulent rien dire ailleurs.
  'call_ringtone_active_path',
  'call_ringtone_custom_list',
  'call_ringtone_native_name',
  // Journal de ce qui a déjà été exporté vers la galerie de CET appareil.
  'exported_media_msg_ids_v2',
  // Drapeaux d'écrans déjà vus : le nouvel appareil doit les revoir.
  'asked_battery_opt_v2',
  'nav_calls_last_visit_ms',
  // Fait sur le serveur, réappris à la première réponse 410.
  'media_retention_days_learned',
  // État des sauvegardes faites depuis CET appareil. Le restaurer ailleurs
  // ferait croire à une sauvegarde qui n'a jamais eu lieu sur le nouveau
  // téléphone, et retarderait d'autant la première vraie.
  'backup_last_success_at',
  'backup_last_attempt_at',
  'backup_consecutive_failures',
  // Début de la série d'échecs et date de la dernière copie de secours, sur
  // CET appareil.
  'backup_first_failure_at',
  'backup_last_fallback_at',
  // Étape de restauration de CET appareil. La restaurer serait absurde : une
  // sauvegarde qui contiendrait « restauration terminée » ferait sauter la
  // restauration suivante sur le téléphone d'après.
  'restore_stage',
  'restore_started_at',
};

/// Déjà synchronisées par compte côté serveur. Les mettre aussi dans la
/// sauvegarde créerait deux sources de vérité, et un conflit le jour où elles
/// divergent.
const Set<String> kServerOwnedKeys = {
  // Sonneries de liste : synchronisées par compte (migration serveur 055).
  'call_ringtone_selected_id',
};

/// Toutes les clés classées, tous statuts confondus.
Set<String> get kClassifiedPrefKeys =>
    {...kBackedUpKeys, ...kDeviceLocalKeys, ...kServerOwnedKeys};

/// Extrait de `prefs` les seules clés à sauvegarder.
///
/// [read] rend la valeur d'une clé, ou `null` si elle n'est pas posée. Passer
/// une fonction plutôt que l'objet `SharedPreferences` garde ce fichier
/// testable sans plateforme.
Map<String, Object> collectBackedUpPrefs(Object? Function(String key) read) {
  final out = <String, Object>{};
  for (final key in kBackedUpKeys) {
    final value = read(key);
    if (value != null) out[key] = value;
  }
  return out;
}

/// Filtre un `prefs.json` relu depuis une sauvegarde.
///
/// La liste blanche s'applique **aussi à la lecture**, et pas seulement à
/// l'écriture : une archive fabriquée à la main, ou produite par une version
/// dont la liste était plus large, ne doit pas pouvoir injecter n'importe quoi
/// dans les préférences de l'appareil.
Map<String, Object> filterRestorablePrefs(Map<String, dynamic> stored) {
  final out = <String, Object>{};
  for (final entry in stored.entries) {
    if (!kBackedUpKeys.contains(entry.key)) continue;
    final value = entry.value;
    if (value is String || value is bool || value is int || value is double) {
      out[entry.key] = value as Object;
    } else if (value is List) {
      // `SharedPreferences` n'accepte que des listes de chaînes.
      out[entry.key] = value.map((e) => e.toString()).toList();
    }
  }
  return out;
}
