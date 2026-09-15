// Historique des appels (part of talky_api_client.dart).
// Les appels eux-mêmes se font par Socket (call_user etc.), pas en HTTP.
part of '../talky_api_client.dart';

extension CallsApi on TalkyApiClient {
  /// Historique paginé, du plus récent au plus ancien.
  ///
  /// [before] = idCall du plus ancien appel déjà en main : la réponse reprend
  /// juste en dessous. Une page plus courte que [limit] signale la fin.
  ///
  /// Le curseur est transmis tel quel dès qu'il existe — voir `sendsCursor`. Le
  /// filtrer sur `> 0` confondait un `idCall` à 0 avec « pas de curseur » et
  /// défaisait la protection que le serveur applique sur un curseur inconnu.
  Future<List<dynamic>> getCallHistory({int? before, int limit = 50}) async {
    final uri = Uri.parse('${TalkyApiClient.baseUrl}/calls').replace(
      queryParameters: {
        'limit': '$limit',
        if (sendsCursor(before)) 'before': '$before',
      },
    );
    final data = await _handleRequest(() => _client.get(uri, headers: _headers));
    return data is List ? data : [];
  }

  /// Crée l'entrée en DB (utilisé si besoin — sinon le socket le fait)
  Future<Map<String, dynamic>> createCallRecord({
    required int idReceiver,
    int type = 0, // 0=audio, 1=vidéo
  }) async {
    final data = await _handleRequest(
      () => _client.post(
        Uri.parse('${TalkyApiClient.baseUrl}/calls'),
        headers: _headers,
        body: jsonEncode({'idReceiver': idReceiver, 'type': type}),
      ),
    );
    return data as Map<String, dynamic>;
  }

  Future<void> endCallRecord(int idCall, {int status = 1}) async {
    await _handleRequest(
      () => _client.put(
        Uri.parse('${TalkyApiClient.baseUrl}/calls/$idCall/end'),
        headers: _headers,
        body: jsonEncode({'status': status}),
      ),
    );
  }

  /// Refus d'appel via HTTP (cold-start CallKit — pas besoin du socket).
  Future<void> rejectCallHttp({
    required int callerId,
    String? callId,
  }) async {
    await _handleRequest(
      () => _client.post(
        Uri.parse('${TalkyApiClient.baseUrl}/calls/reject'),
        headers: _headers,
        body: jsonEncode({
          'callerId': callerId,
          if (callId != null && callId.isNotEmpty) 'callId': callId,
        }),
      ),
    );
  }
}
