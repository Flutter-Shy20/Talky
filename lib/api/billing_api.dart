part of '../talky_api_client.dart';

/// Abonnement Alanya Plus.
extension BillingApi on TalkyApiClient {
  /// Droits du compte connecté — même charge utile que la clé `entitlements`
  /// de `/auth/me`. Sert au rafraîchissement ciblé, sans relire le profil.
  Future<Map<String, dynamic>> getMyEntitlements() async {
    final data = await _handleRequest(
      () => _client.get(
        Uri.parse('${TalkyApiClient.baseUrl}/billing/me'),
        headers: _headers,
      ),
    );
    return Map<String, dynamic>.from(data as Map);
  }
}
