// Endpoints de sauvegarde : clés de chiffrement et métadonnée de compte
// (part of talky_api_client.dart).
part of '../talky_api_client.dart';

extension BackupApi on TalkyApiClient {
  /// Clé de chiffrement des sauvegardes.
  ///
  /// Sans [kid], la version courante — pour écrire. Avec, la version demandée
  /// — pour relire une archive ancienne, dont l'en-tête en clair porte
  /// justement ce numéro. C'est ce couple qui permet au serveur de remplacer
  /// son secret sans rendre illisibles les sauvegardes déjà déposées.
  ///
  /// La clé n'est jamais conservée : elle est demandée au moment de
  /// sauvegarder, redemandée au moment de restaurer, et oubliée entre les
  /// deux.
  Future<Map<String, dynamic>> fetchBackupKey({int? kid}) async {
    final path = kid == null ? '/backup/key' : '/backup/key/$kid';
    final data = await _handleRequest(
      () => _client.get(
        Uri.parse('${TalkyApiClient.baseUrl}$path'),
        headers: _headers,
      ),
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Parmi ces médias, lesquels le serveur détient-il encore ?
  ///
  /// Interrogé avant un export, pour annoncer un décompte et un poids **exacts**
  /// au lieu d'une devinette. Le client, seul, ne peut que déduire l'expiration
  /// d'une durée de rétention qu'il n'a pas toujours apprise — et croit alors
  /// tout récupérable, promettant des téléchargements voués au `410`.
  ///
  /// Économise de la bande passante plutôt que d'en dépenser : quelques
  /// kilo-octets remplacent des dizaines de téléchargements perdus.
  Future<Map<String, dynamic>> fetchMediaAvailability(List<int> msgIDs) async {
    final data = await _handleRequest(
      () => _client.post(
        Uri.parse('${TalkyApiClient.baseUrl}/media/availability'),
        headers: _headers,
        body: jsonEncode({'msgIDs': msgIDs}),
      ),
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Ce que le serveur sait de la dernière sauvegarde du compte.
  ///
  /// Interrogé à la connexion sur un appareil neuf, **avant** toute demande de
  /// compte Google. Sans cette information, il faudrait fouiller Drive à
  /// l'aveugle au premier démarrage — donc réclamer un compte tiers au pire
  /// moment, y compris à quelqu'un qui n'a jamais rien sauvegardé.
  ///
  /// `hasBackup: false` est une réponse, pas une erreur.
  Future<Map<String, dynamic>> fetchBackupMeta() async {
    final data = await _handleRequest(
      () => _client.get(
        Uri.parse('${TalkyApiClient.baseUrl}/backup/meta'),
        headers: _headers,
      ),
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Déclare qu'une sauvegarde a réussi.
  ///
  /// **Aucun contenu ne transite** : une date, une taille, une version de clé,
  /// un décompte, et l'adresse Google que le serveur stockera masquée.
  Future<void> publishBackupMeta({
    required int bytes,
    required int kid,
    int? messageCount,
    String? accountEmail,
  }) async {
    await _handleRequest(
      () => _client.put(
        Uri.parse('${TalkyApiClient.baseUrl}/backup/meta'),
        headers: _headers,
        body: jsonEncode({
          'bytes': bytes,
          'kid': kid,
          if (messageCount != null) 'messageCount': messageCount,
          if (accountEmail != null) 'accountEmail': accountEmail,
        }),
      ),
    );
  }
}
