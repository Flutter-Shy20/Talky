part of '../talky_api_client.dart';

extension KeysApi on TalkyApiClient {
  /// Upload le bundle Signal complet (IK, SPK signé, OTPKs) au serveur.
  /// Le backend remplace les OTPKs existantes (idempotent).
  Future<void> uploadBundle(Map<String, dynamic> bundle) async {
    await _handleRequest(() => _client.post(
          Uri.parse('${TalkyApiClient.baseUrl}/keys/upload'),
          headers: _headers,
          body: jsonEncode(bundle),
        ));
  }

  /// Récupère le bundle de préclés d'un utilisateur pour initier X3DH.
  /// Retourne :
  ///   { identityKeyDh, identityKeySign,
  ///     signedPrekey: { keyId, publicKey, signature },
  ///     prekey: { keyId, publicKey } | null }
  Future<Map<String, dynamic>> fetchKeyBundle(int userId) async {
    final data = await _handleRequest(() => _client.get(
          Uri.parse('${TalkyApiClient.baseUrl}/keys/$userId/bundle'),
          headers: _headers,
        ));
    return Map<String, dynamic>.from(data as Map);
  }

  /// Nombre de one-time prekeys restantes sur le serveur (pour planifier la rotation).
  Future<int> fetchKeyCount() async {
    final data = await _handleRequest(() => _client.get(
          Uri.parse('${TalkyApiClient.baseUrl}/keys/count'),
          headers: _headers,
        ));
    return (data as Map)['count'] as int? ?? 0;
  }
}
