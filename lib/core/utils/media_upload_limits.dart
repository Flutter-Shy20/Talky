/// Poids maximal d'un fichier envoyé (photo, vidéo, audio, document) au palier
/// standard, en octets : la valeur qui s'applique tant que le serveur n'a rien
/// annoncé (voir [MediaUploadLimits]).
///
/// Aligné sur `TIER_LIMITS.standard` du backend (`src/constants/billing.js`).
/// Pour une vidéo, c'est le fichier qui partira qui compte — la sortie de la
/// compression — et non le fichier filmé : voir
/// `VideoUploadCompressor.estimateUploadBytes`.
const int kMaxMediaUploadBytes = 100 * 1024 * 1024;

/// Nombre maximal de médias d'un album au palier standard.
const int kMaxAlbumItems = 30;

/// Plus haut plafond d'envoi, tous paliers confondus (abonné Alanya Plus,
/// `TIER_LIMITS.paid` du backend). Sert au téléchargement : un compte standard
/// doit pouvoir recevoir ce qu'un abonné lui envoie.
const int kMaxReceivedMediaBytes = 200 * 1024 * 1024;

/// Plafonds d'envoi de CE compte.
///
/// Le serveur les annonce avec les droits du compte (`limits`) : 100 Mo et 30
/// médias par album au palier standard, 200 Mo et 100 médias pour un abonné
/// Alanya Plus. Il fait respecter la taille de son côté, dès la demande de
/// ticket ; l'app applique les deux dès le choix du fichier, pour refuser tout
/// de suite plutôt qu'après un envoi qui échoue.
class MediaUploadLimits {
  MediaUploadLimits._();

  static int _maxBytes = kMaxMediaUploadBytes;
  static int _maxAlbumItems = kMaxAlbumItems;

  /// Poids maximal d'un fichier, en octets.
  static int get maxBytes => _maxBytes;

  /// [maxBytes] en Mo, pour les messages affichés.
  static int get maxMegabytes => _maxBytes ~/ (1024 * 1024);

  /// Nombre maximal de médias d'un album.
  static int get maxAlbumItems => _maxAlbumItems;

  /// Plafonds lus dans les droits du compte. `null` (déconnexion, droits
  /// inconnus, serveur antérieur) : retour au palier standard.
  static void apply({int? maxBytes, int? maxAlbumItems}) {
    _maxBytes =
        (maxBytes != null && maxBytes > 0) ? maxBytes : kMaxMediaUploadBytes;
    _maxAlbumItems = (maxAlbumItems != null && maxAlbumItems > 0)
        ? maxAlbumItems
        : kMaxAlbumItems;
  }
}
