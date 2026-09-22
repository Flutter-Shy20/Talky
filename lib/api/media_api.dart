// Upload de fichiers (avatar, médias de chat) — part of talky_api_client.dart.
part of '../talky_api_client.dart';

extension MediaApi on TalkyApiClient {
  /// Héberge une image côté serveur et retourne `{ url, filename }`.
  /// Ne met pas à jour le profil — utiliser [AuthProvider.updateAvatar] pour un avatar personnel.
  Future<Map<String, dynamic>> uploadImage(File file) async {
    final request = http.MultipartRequest('POST', Uri.parse('${TalkyApiClient.baseUrl}/upload/avatar'));
    request.headers['Authorization'] = 'Bearer $_accessToken';
    request.files.add(await _multipartFile('file', file));
    final streamed = await request.send().timeout(const Duration(seconds: 60));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw uploadHttpException(response);
  }

  /// Alias de [uploadImage] — préférer [uploadImage] hors contexte profil.
  Future<Map<String, dynamic>> uploadAvatar(File file) => uploadImage(file);

  Future<Map<String, dynamic>> uploadMedia(
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    final timeout = uploadTimeoutForFileSize(await file.length());
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${TalkyApiClient.baseUrl}/upload/media'),
    );
    request.headers['Authorization'] = 'Bearer $_accessToken';
    request.files.add(await _multipartFile('file', file, onProgress: onProgress));
    final streamed = await request.send().timeout(timeout);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw uploadHttpException(response);
  }

  /// Dépose l'annonce vocale du répondeur, et remplace la précédente.
  ///
  /// Route distincte de `uploadMedia`, et ce n'est pas un détail : celle-ci
  /// range le fichier dans `uploads/media/<jour>/`, dont la purge des
  /// partitions supprime le répertoire entier au bout de la rétention, sans
  /// consulter aucune table. L'annonce y disparaîtrait d'elle-même.
  ///
  /// Le serveur renvoie une URL au nom NOUVEAU à chaque dépôt : c'est ce qui
  /// invalide le cache des appelants, qui indexe par nom de fichier.
  Future<Map<String, dynamic>> uploadVoicemailGreeting(
    File file, {
    required int seconds,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${TalkyApiClient.baseUrl}/upload/voicemail-greeting'),
    );
    request.headers['Authorization'] = 'Bearer $_accessToken';
    request.fields['seconds'] = seconds.toString();
    request.files.add(await _multipartFile('file', file));
    final streamed = await request.send().timeout(const Duration(seconds: 60));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw uploadHttpException(response);
  }

  Future<void> deleteVoicemailGreeting() async {
    final response = await _client
        .delete(
          Uri.parse('${TalkyApiClient.baseUrl}/upload/voicemail-greeting'),
          headers: {'Authorization': 'Bearer $_accessToken'},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw uploadHttpException(response);
  }
}
