// Partage de position dans le chat.
//
// Une position est transportée comme un message texte (type 0) dont le
// `content` est un marqueur spécial. Aucun changement de schéma ni de backend
// n'est nécessaire : le message circule, se synchronise et se transfère comme
// un texte normal, mais l'UI le rend sous forme d'aperçu cartographique.

/// Préfixe du marqueur position stocké dans `content`.
const locationMarkerPrefix = '__talky_location__';

/// Coordonnées décodées depuis un marqueur position.
class LocationMarker {
  const LocationMarker({
    required this.latitude,
    required this.longitude,
    this.label,
  });

  final double latitude;
  final double longitude;

  /// Libellé optionnel (adresse ou nom de lieu).
  final String? label;
}

/// Encode une position dans `content` : `__talky_location__|lat|lng|label`.
String encodeLocationMarker({
  required double latitude,
  required double longitude,
  String? label,
}) {
  final safeLabel = (label ?? '').replaceAll('\n', ' ').trim();
  return '$locationMarkerPrefix|$latitude|$longitude|$safeLabel';
}

/// Décode un marqueur position depuis `content`, ou `null` si absent/invalide.
LocationMarker? parseLocationMarker(String? content) {
  if (content == null || !content.startsWith(locationMarkerPrefix)) return null;
  final parts = content.split('|');
  if (parts.length < 3) return null;
  final lat = double.tryParse(parts[1]);
  final lng = double.tryParse(parts[2]);
  if (lat == null || lng == null) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  final label = parts.length > 3 ? parts.sublist(3).join('|').trim() : '';
  return LocationMarker(
    latitude: lat,
    longitude: lng,
    label: label.isEmpty ? null : label,
  );
}

bool isLocationMarkerContent(String? content) =>
    parseLocationMarker(content) != null;

/// Libellé d'aperçu pour la liste des conversations.
const String locationPreviewLabel = '📍 Position';

/// Lien d'ouverture dans Google Maps (app native ou navigateur).
Uri googleMapsUri(double latitude, double longitude) {
  return Uri.parse(
    'https://www.google.com/maps/search/?api=1'
    '&query=$latitude,$longitude',
  );
}

/// Vignette carte statique (OpenStreetMap, sans clé API) pour l'aperçu.
/// Si le service est indisponible, l'UI retombe sur un fond illustré.
String osmStaticMapUrl(
  double latitude,
  double longitude, {
  int zoom = 15,
  int width = 600,
  int height = 320,
}) {
  return 'https://staticmap.openstreetmap.de/staticmap.php'
      '?center=$latitude,$longitude'
      '&zoom=$zoom'
      '&size=${width}x$height'
      '&markers=$latitude,$longitude,red-pushpin';
}

/// Coordonnées formatées de façon compacte (4 décimales).
String formatLatLng(double latitude, double longitude) {
  return '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';
}