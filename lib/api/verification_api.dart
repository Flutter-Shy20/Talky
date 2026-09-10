part of '../talky_api_client.dart';

/// Vérification d'identité — la coche.
///
/// Les pièces partent en multipart vers le coffre chiffré du serveur ; elles
/// ne transitent jamais par le chemin des médias, servi en statique.
extension VerificationApi on TalkyApiClient {
  /// Dossier, pièces et coche du compte connecté.
  Future<Map<String, dynamic>> getVerification() async {
    final data = await _handleRequest(
      () => _client.get(
        Uri.parse('${TalkyApiClient.baseUrl}/verification'),
        headers: _headers,
      ),
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Dépose une demande : une ou deux faces de la pièce, et un selfie.
  Future<Map<String, dynamic>> submitVerification({
    required List<File> identity,
    required File selfie,
  }) =>
      _sendPieces('/verification', identity: identity, selfie: selfie);

  /// Complète un dossier en « pièce demandée ».
  Future<Map<String, dynamic>> addVerificationDocuments({
    List<File> identity = const [],
    File? selfie,
  }) =>
      _sendPieces('/verification/documents', identity: identity, selfie: selfie);

  /// Annule la demande en cours ; les pièces sont détruites.
  Future<Map<String, dynamic>> cancelVerification() async {
    final data = await _handleRequest(
      () => _client.delete(
        Uri.parse('${TalkyApiClient.baseUrl}/verification'),
        headers: _headers,
      ),
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> _sendPieces(
    String path, {
    required List<File> identity,
    File? selfie,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${TalkyApiClient.baseUrl}$path'),
    );
    request.headers['Authorization'] = 'Bearer $_accessToken';
    for (final file in identity) {
      request.files.add(await _multipartFile('identity', file));
    }
    if (selfie != null) request.files.add(await _multipartFile('selfie', selfie));
    final streamed = await request.send().timeout(const Duration(seconds: 90));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 200 || response.statusCode == 201) {
      return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    }
    throw uploadHttpException(response);
  }
}
