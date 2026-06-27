part of '../talky_api_client.dart';

extension VaultApi on TalkyApiClient {
  /// Récupère le sel de coffre (vault_salt) du serveur pour l'utilisateur courant.
  /// Le serveur génère ce sel à l'inscription et ne le modifie jamais.
  /// Retourne les bytes bruts décodés depuis base64.
  Future<List<int>> fetchVaultSalt() async {
    final data = await _handleRequest(() => _client.get(
          Uri.parse('${TalkyApiClient.baseUrl}/vault/salt'),
          headers: _headers,
        ));
    final b64 = (data as Map)['vaultSalt'] as String;
    return base64Decode(b64);
  }

  /// Récupère l'historique des messages archivés (archive_blob) pour une conversation.
  /// Utilisé sur un nouvel appareil pour reconstruire l'historique des messages envoyés.
  /// Retourne une liste de `{ msgID, archive_blob, archive_nonce, sendAt, ... }`.
  Future<List<Map<String, dynamic>>> fetchVaultHistory(int conversationId) async {
    final data = await _handleRequest(() => _client.get(
          Uri.parse(
              '${TalkyApiClient.baseUrl}/vault/history?conversationId=$conversationId'),
          headers: _headers,
        ));
    return (data as List).whereType<Map<String, dynamic>>().toList();
  }
}
