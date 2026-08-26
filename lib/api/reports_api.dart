// Endpoints signalement d'abus (part of talky_api_client.dart).
part of '../talky_api_client.dart';

extension ReportsApi on TalkyApiClient {
  /// Signale un message ou un compte.
  ///
  /// [targetType] vaut `message` ou `user`. Le serveur renvoie `duplicate`
  /// quand la cible avait déjà été signalée par ce compte — ce n'est pas une
  /// erreur : la plainte est enregistrée, l'écran dit merci dans les deux cas.
  Future<bool> sendReport({
    required String targetType,
    required int targetId,
    required String reason,
    String? note,
  }) async {
    final data = await _handleRequest(
      () => _client.post(
        Uri.parse('${TalkyApiClient.baseUrl}/reports'),
        headers: _headers,
        body: jsonEncode({
          'targetType': targetType,
          'targetId': targetId,
          'reason': reason,
          if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        }),
      ),
    );
    return data is Map && data['duplicate'] == true;
  }
}
