/// Expiration des médias serveur — miroir client de la logique de partitions.
///
/// Le serveur range les médias en tranches de 24 heures et fait tomber celles
/// qui ont dépassé la rétention. Le chemin porte donc la date d'upload :
///
///     https://…/uploads/media/2026-08-24/images/media_51_1756000000000.jpg
///                            └─ la partition
///
/// Cette information étant dans l'URL, **le client peut savoir qu'un média est
/// mort sans faire la moindre requête**. C'est ce qui permet d'afficher
/// « Média expiré » immédiatement, au lieu de lancer un téléchargement voué à
/// l'échec, d'attendre le délai réseau, puis d'afficher une image cassée
/// impossible à distinguer d'une panne de connexion.
///
/// ── La durée de rétention n'est pas codée en dur ──
///
/// Elle est réglable côté serveur (variable d'environnement, et surcharge
/// depuis l'espace super-admin) : la figer ici garantirait qu'un jour les deux
/// divergent, et le client afficherait « expiré » sur des médias vivants — ou
/// l'inverse. Le client l'APPREND donc du serveur : chaque réponse `410` porte
/// le champ `retentionDays`, qui est mémorisé pour les décisions suivantes.
///
/// Tant que rien n'a été appris, [isMediaExpired] répond `false` : on préfère
/// une tentative inutile à une image masquée à tort.
library;

/// Réponse du serveur quand un média a dépassé sa rétention.
/// Contrat côté backend : `middleware/mediaExpiry.js`.
const String kMediaExpiredError = 'MEDIA_EXPIRED';

/// Code HTTP correspondant. Volontairement distinct de 404 : « ce média a
/// existé et n'existe plus » n'est pas « cette adresse n'a jamais rien
/// désigné ». Le premier est définitif, le second peut être une panne.
const int kMediaGoneStatus = 410;

final RegExp _partitionDansUrl = RegExp(r'/uploads/media/(\d{4})-(\d{2})-(\d{2})/');

/// Clé de partition (`AAAA-MM-JJ`) contenue dans une URL de média.
///
/// `null` si l'URL n'est pas partitionnée : avatar, adresse héritée d'avant la
/// migration, ou chemin quelconque. `null` ne veut donc PAS dire « expiré »
/// mais « je ne peux pas savoir » — l'appelant laisse alors la requête partir
/// et se fie à la réponse du serveur.
String? partitionFromMediaUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  final m = _partitionDansUrl.firstMatch(url);
  if (m == null) return null;
  final annee = int.parse(m.group(1)!);
  final mois = int.parse(m.group(2)!);
  final jour = int.parse(m.group(3)!);
  // Contrôle de réalité : `2026-02-31` a la bonne forme mais n'existe pas, et
  // DateTime.utc la normaliserait silencieusement vers un autre jour.
  final d = DateTime.utc(annee, mois, jour);
  if (d.year != annee || d.month != mois || d.day != jour) return null;
  return m.group(0)!.substring('/uploads/media/'.length, m.group(0)!.length - 1);
}

/// Instant à partir duquel la partition est tombée côté serveur.
///
/// Une partition `D` contient les uploads de `[D, D+1)`. Son fichier le plus
/// récent a donc été déposé juste avant `D+1` et doit vivre `retentionDays` :
/// la tranche n'est effaçable qu'à `D + 1 jour + retentionDays`. Ce calcul est
/// le strict miroir de `partitionExpiresAtMs` côté serveur — les deux doivent
/// rester identiques, sans quoi le client masquerait des médias encore servis.
DateTime? partitionExpiresAt(String? partition, int retentionDays) {
  if (partition == null) return null;
  final parts = partition.split('-');
  if (parts.length != 3) return null;
  final annee = int.tryParse(parts[0]);
  final mois = int.tryParse(parts[1]);
  final jour = int.tryParse(parts[2]);
  if (annee == null || mois == null || jour == null) return null;
  final debut = DateTime.utc(annee, mois, jour);
  if (debut.year != annee || debut.month != mois || debut.day != jour) return null;
  return debut.add(Duration(days: retentionDays + 1));
}

/// `true` si ce média est certainement mort côté serveur.
///
/// Prudent par construction : répond `false` dès qu'un doute existe — URL non
/// partitionnée, rétention inconnue, date illisible. Un faux négatif coûte une
/// requête inutile ; un faux positif masquerait un média que l'utilisateur
/// pourrait encore voir.
bool isMediaExpired(
  String? url, {
  required int? retentionDays,
  DateTime? now,
}) {
  if (retentionDays == null || retentionDays <= 0) return false;
  final echeance = partitionExpiresAt(partitionFromMediaUrl(url), retentionDays);
  if (echeance == null) return false;
  return !(now ?? DateTime.now().toUtc()).toUtc().isBefore(echeance);
}
