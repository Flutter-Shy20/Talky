// Upload de fichiers (avatar, médias de chat) — part of talky_api_client.dart.
part of '../talky_api_client.dart';

extension MediaApi on TalkyApiClient {
  // Blob média déjà chiffré côté client par chunks (AES-256-GCM, voir
  // MediaCipherService.encryptFileStreaming). Contenu opaque : pas de
  // détection de MIME, le serveur ne doit rien savoir du fichier réel (voir
  // MEDIAS_E2EE.md). Le flux est streamé de bout en bout — jamais bufferisé
  // entièrement en mémoire ([length] est connu à l'avance car le format de
  // chiffrement par chunks a une taille déterministe, voir
  // `MediaCipherService.encryptedLengthFor`).
  Future<Map<String, dynamic>> uploadEncryptedStream(
      Stream<List<int>> stream, int length) async {
    final request = http.MultipartRequest('POST', Uri.parse('${TalkyApiClient.baseUrl}/media/upload'));
    request.headers['Authorization'] = 'Bearer $_accessToken';
    request.files.add(http.MultipartFile('file', stream, length, filename: 'blob.bin'));
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw TalkyException(jsonDecode(response.body)['error'] ?? 'Upload échoué', response.statusCode);
  }

  /// Télécharge le blob chiffré en streaming (le corps de la réponse n'est
  /// jamais bufferisé entièrement — consommé au fil de l'eau par
  /// `MediaCipherService.decryptStreaming`).
  Stream<List<int>> downloadMediaBlobStreaming(int id) async* {
    final request = http.Request('GET', Uri.parse('${TalkyApiClient.baseUrl}/media/$id'));
    request.headers['Authorization'] = 'Bearer $_accessToken';
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      var message = 'Téléchargement échoué';
      try {
        message = jsonDecode(body)['error'] ?? message;
      } catch (_) {}
      throw TalkyException(message, response.statusCode);
    }
    yield* response.stream;
  }

  Future<Map<String, dynamic>> uploadAvatar(File file) async {
    final request = http.MultipartRequest('POST', Uri.parse('${TalkyApiClient.baseUrl}/upload/avatar'));
    request.headers['Authorization'] = 'Bearer $_accessToken';
    request.files.add(await _multipartFile('file', file));
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw TalkyException(jsonDecode(response.body)['error'] ?? 'Upload échoué', response.statusCode);
  }

  Future<Map<String, dynamic>> uploadMedia(File file) async {
    final request = http.MultipartRequest('POST', Uri.parse('${TalkyApiClient.baseUrl}/upload/media'));
    request.headers['Authorization'] = 'Bearer $_accessToken';
    request.files.add(await _multipartFile('file', file));
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw TalkyException(jsonDecode(response.body)['error'] ?? 'Upload échoué', response.statusCode);
  }
}
