// Upload de fichiers (avatar, médias de chat) — part of talky_api_client.dart.
part of '../talky_api_client.dart';

// Deux chemins d'envoi, choisis par le serveur :
//
// - **Direct** : l'app demande un lien d'envoi signé (`POST /upload/ticket`),
//   puis envoie le fichier directement au stockage objet (Backblaze B2) par
//   `PUT`. Un seul trajet, sans détour par le serveur de l'API.
// - **Formulaire** : l'envoi historique, `POST /upload/media` ou
//   `/upload/avatar` en multipart. Le serveur le demande (`mode: multipart`)
//   tant que le stockage objet n'est pas actif ; c'est aussi le repli face à un
//   serveur trop ancien pour connaître la route de ticket (404).
//
// Les deux chemins rendent la même structure : les appelants ne savent pas
// lequel a servi.

extension MediaApi on TalkyApiClient {
  /// Héberge une image côté serveur et retourne `{ url, filename }`.
  /// Ne met pas à jour le profil — utiliser [AuthProvider.updateAvatar] pour un avatar personnel.
  Future<Map<String, dynamic>> uploadImage(File file) => _uploadFile(
        file,
        kind: 'avatar',
        multipartPath: '/upload/avatar',
        timeout: const Duration(seconds: 60),
      );

  /// Alias de [uploadImage] — préférer [uploadImage] hors contexte profil.
  Future<Map<String, dynamic>> uploadAvatar(File file) => uploadImage(file);

  Future<Map<String, dynamic>> uploadMedia(
    File file, {
    void Function(double progress)? onProgress,
  }) async =>
      _uploadFile(
        file,
        kind: 'media',
        multipartPath: '/upload/media',
        timeout: uploadTimeoutForFileSize(await file.length()),
        onProgress: onProgress,
      );

  Future<Map<String, dynamic>> _uploadFile(
    File file, {
    required String kind,
    required String multipartPath,
    required Duration timeout,
    void Function(double progress)? onProgress,
  }) async {
    final ticket = await _requestUploadTicket(file, kind: kind);
    if (ticket != null) {
      return _putDirect(file, ticket, timeout: timeout, onProgress: onProgress);
    }
    return _postMultipart(
      file,
      multipartPath,
      timeout: timeout,
      onProgress: onProgress,
    );
  }

  /// Ticket d'envoi direct, ou `null` quand le serveur demande le formulaire.
  ///
  /// Un refus (type non autorisé, fichier trop lourd…) lève comme l'aurait
  /// fait l'envoi par formulaire : ce sont les mêmes règles, appliquées avant
  /// d'envoyer le moindre octet.
  Future<Map<String, dynamic>?> _requestUploadTicket(
    File file, {
    required String kind,
  }) async {
    final response = await _client
        .post(
          Uri.parse('${TalkyApiClient.baseUrl}/upload/ticket'),
          headers: {
            'Authorization': 'Bearer $_accessToken',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'kind': kind,
            'mimetype': mimeTypeForPath(file.path).mimeType,
            'size': await file.length(),
            'fileName': file.path.split('/').last,
          }),
        )
        .timeout(const Duration(seconds: 30));
    // Serveur antérieur à la route : on envoie comme avant.
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) throw uploadHttpException(response);
    final body = jsonDecode(response.body);
    if (body is Map<String, dynamic> &&
        body['mode'] == 'direct' &&
        body['uploadUrl'] is String) {
      return body;
    }
    return null;
  }

  /// Envoi direct au stockage objet, avec le lien signé du ticket.
  ///
  /// Le jeton de l'API n'est jamais joint : le lien signé suffit, et le jeton
  /// n'a rien à faire chez un tiers.
  Future<Map<String, dynamic>> _putDirect(
    File file,
    Map<String, dynamic> ticket, {
    required Duration timeout,
    void Function(double progress)? onProgress,
  }) async {
    final length = await file.length();
    final request =
        http.StreamedRequest('PUT', Uri.parse(ticket['uploadUrl'] as String));
    // En-têtes signés : ils doivent partir à l'identique, sinon le stockage
    // refuse l'envoi. La taille, elle aussi signée, est posée ici.
    final headers = ticket['headers'];
    if (headers is Map) {
      headers.forEach((k, v) => request.headers['$k'] = '$v');
    }
    request.contentLength = length;
    var sent = 0;
    unawaited(file.openRead().map((chunk) {
      sent += chunk.length;
      if (length > 0) onProgress?.call(sent / length);
      return chunk;
    }).pipe(request.sink));

    final streamed = await _client.send(request).timeout(timeout);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw uploadHttpException(response);
    }
    return {
      'url': ticket['url'],
      'filename': ticket['filename'],
      'originalName': file.path.split('/').last,
      'mimetype': ticket['mimetype'],
      'size': ticket['size'] ?? length,
      'msgType': ticket['msgType'],
    };
  }

  /// Envoi historique, par formulaire, au serveur de l'API.
  Future<Map<String, dynamic>> _postMultipart(
    File file,
    String path, {
    required Duration timeout,
    void Function(double progress)? onProgress,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${TalkyApiClient.baseUrl}$path'),
    );
    request.headers['Authorization'] = 'Bearer $_accessToken';
    request.files.add(await _multipartFile('file', file, onProgress: onProgress));
    // Client partagé de l'API : la connexion déjà ouverte vers le serveur sert
    // aussi à l'envoi, au lieu d'en ouvrir une neuve par fichier.
    final streamed = await _client.send(request).timeout(timeout);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw uploadHttpException(response);
  }
}
