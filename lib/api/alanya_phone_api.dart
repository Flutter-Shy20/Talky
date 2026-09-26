part of '../talky_api_client.dart';

/// Le numéro choisi : vérifier, mettre de côté, payer.
///
/// Les réponses restent des `Map` : leur lecture vit dans
/// core/services/billing/phone_models.dart, éprouvée sans réseau. Comme pour
/// l'abonnement, `checkoutAlanyaPhone` ne dit jamais « payé » : la
/// confirmation arrive par `payment:updated`, le nouveau numéro par
/// `account:phone_changed`.
extension AlanyaPhoneApi on TalkyApiClient {
  /// Prix, moyens de paiement, numéro actuel et commande à reprendre.
  Future<Map<String, dynamic>> getPhoneOffer() async {
    final data = await _handleRequest(
      () => _client.get(
        Uri.parse('${TalkyApiClient.baseUrl}/alanya-phone/offer'),
        headers: _headers,
      ),
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Le numéro est-il à vendre ? Rien n'est retenu.
  Future<Map<String, dynamic>> checkAlanyaPhone(String phone) async {
    final uri = Uri.parse('${TalkyApiClient.baseUrl}/alanya-phone/check')
        .replace(queryParameters: {'phone': phone});
    final data = await _handleRequest(
      () => _client.get(uri, headers: _headers),
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Met le numéro de côté le temps de payer — ou le pose tout de suite s'il
  /// reste un changement déjà payé.
  Future<Map<String, dynamic>> holdAlanyaPhone(String phone) async {
    final data = await _handleRequest(
      () => _client.post(
        Uri.parse('${TalkyApiClient.baseUrl}/alanya-phone/hold'),
        headers: _headers,
        body: jsonEncode({'phone': phone}),
      ),
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Lève sa mise de côté (retour arrière avant de payer).
  Future<void> releaseAlanyaPhoneHold() async {
    await _handleRequest(
      () => _client.delete(
        Uri.parse('${TalkyApiClient.baseUrl}/alanya-phone/hold'),
        headers: _headers,
      ),
    );
  }

  /// Demande le paiement du numéro mis de côté.
  Future<Map<String, dynamic>> checkoutAlanyaPhone({
    required int orderId,
    required String channel,
    required String msisdn,
  }) async {
    final data = await _handleRequest(
      () => _client.post(
        Uri.parse('${TalkyApiClient.baseUrl}/alanya-phone/checkout'),
        headers: _headers,
        body: jsonEncode({
          'orderId': orderId,
          'channel': channel,
          'msisdn': msisdn,
        }),
      ),
    );
    return Map<String, dynamic>.from(data as Map);
  }
}
