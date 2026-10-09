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
      );

  /// Alias de [uploadImage] — préférer [uploadImage] hors contexte profil.
  Future<Map<String, dynamic>> uploadAvatar(File file) => uploadImage(file);

  /// Envoie un média de discussion ou de statut.
  ///
  /// Aucune durée totale n'est imposée : un gros fichier sur une connexion
  /// lente peut prendre plusieurs minutes. L'envoi n'est abandonné que s'il
  /// cesse d'avancer (voir [UploadStallGuard]).
  Future<Map<String, dynamic>> uploadMedia(
    File file, {
    void Function(double progress)? onProgress,
  }) =>
      _uploadFile(
        file,
        kind: 'media',
        multipartPath: '/upload/media',
        onProgress: onProgress,
      );

  Future<Map<String, dynamic>> _uploadFile(
    File file, {
    required String kind,
    required String multipartPath,
    void Function(double progress)? onProgress,
  }) async {
    final ticket = await _requestUploadTicket(file, kind: kind);
    if (ticket != null) {
      try {
        return await _putDirect(file, ticket, onProgress: onProgress);
      } on TalkyException catch (e) {
        // Lien signé périmé (TTL 15 min) ou refusé par le stockage : un nouveau
        // ticket, une seule fois. Un 413 / 400 de validation ne passe pas ici —
        // ils sont levés avant le PUT, à la demande de ticket.
        if (e.statusCode == 400 || e.statusCode == 403) {
          final retry = await _requestUploadTicket(file, kind: kind);
          if (retry != null) {
            return _putDirect(file, retry, onProgress: onProgress);
          }
        }
        rethrow;
      }
    }
    return _postMultipart(file, multipartPath, onProgress: onProgress);
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
    void Function(double progress)? onProgress,
  }) async {
    final length = await file.length();
    final guard = UploadStallGuard(stallTimeout: uploadStallTimeout);
    final request = http.AbortableStreamedRequest(
      'PUT',
      Uri.parse(ticket['uploadUrl'] as String),
      abortTrigger: guard.abortTrigger,
    );
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
      guard.tick();
      if (length > 0) onProgress?.call(sent / length);
      return chunk;
    }).pipe(request.sink));

    final response = await _sendGuarded(request, guard);
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
    void Function(double progress)? onProgress,
  }) async {
    final guard = UploadStallGuard(stallTimeout: uploadStallTimeout);
    final request = http.AbortableMultipartRequest(
      'POST',
      Uri.parse('${TalkyApiClient.baseUrl}$path'),
      abortTrigger: guard.abortTrigger,
    );
    request.headers['Authorization'] = 'Bearer $_accessToken';
    request.files.add(await _multipartFile(
      'file',
      file,
      onProgress: (p) {
        guard.tick();
        onProgress?.call(p);
      },
    ));
    // Client partagé de l'API : la connexion déjà ouverte vers le serveur sert
    // aussi à l'envoi, au lieu d'en ouvrir une neuve par fichier.
    final response = await _sendGuarded(request, guard);
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw uploadHttpException(response);
  }

  /// Envoie [request] sous la surveillance de [guard].
  ///
  /// Un envoi bloqué lève une erreur réseau (statut 0) : l'appelant la traite
  /// comme passagère et réessaie plus tard. La course avec [guard] ne dépend
  /// pas du client : même un client qui ignore l'interruption rend la main.
  Future<http.Response> _sendGuarded(
    http.BaseRequest request,
    UploadStallGuard guard,
  ) async {
    Future<T> stalled<T>() => guard.abortTrigger
        .then<T>((_) => throw http.RequestAbortedException(request.url));
    try {
      final streamed = await Future.any([_client.send(request), stalled()]);
      return await Future.any([http.Response.fromStream(streamed), stalled()]);
    } on http.RequestAbortedException catch (e) {
      throw TalkyException(resolveL10n().networkTimeout, 0, cause: e);
    } finally {
      guard.stop();
    }
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

  /// Dépose une sonnerie importée, choisie pour une liste, pour que les autres
  /// appareils du compte la retrouvent (ticket `ringtone`, puis envoi direct).
  ///
  /// [sha256] est l'empreinte que la liste synchronise déjà : le serveur en
  /// tire l'adresse du fichier, et répond « déjà là » si ce contenu a déjà
  /// été déposé par ce compte.
  ///
  /// Renvoie l'adresse du fichier, ou `null` quand le serveur ne garde pas
  /// (encore) ces fichiers : route inconnue, ancien serveur, stockage objet
  /// éteint. La sonnerie reste alors sur le téléphone, comme avant. Lève pour
  /// un échec réseau, ou un refus (`SUBSCRIPTION_REQUIRED`).
  Future<String?> uploadListRingtone(
    File file, {
    required String sha256,
  }) async {
    final response = await _client
        .post(
          Uri.parse('${TalkyApiClient.baseUrl}/upload/ticket'),
          headers: {
            'Authorization': 'Bearer $_accessToken',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'kind': 'ringtone',
            'sha256': sha256,
            'mimetype': mimeTypeForPath(file.path).mimeType,
            'size': await file.length(),
          }),
        )
        .timeout(const Duration(seconds: 30));
    // Route inconnue (404) ou type de ticket inconnu (400) : serveur antérieur.
    if (response.statusCode == 404) return null;
    if (response.statusCode == 400) {
      final e = uploadHttpException(response);
      if (e.code == 'VALIDATION_FAILED') return null;
      throw e;
    }
    if (response.statusCode != 200) throw uploadHttpException(response);
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) return null;
    switch (body['mode']) {
      case 'exists':
        return body['url'] as String?;
      case 'direct':
        await _putDirect(file, body);
        return body['url'] as String?;
      default:
        return null;
    }
  }

  /// Télécharge le fichier d'une sonnerie de liste déposée par un autre
  /// appareil du compte. `null` si le fichier manque (jamais déposé) ou
  /// dépasse la taille d'une sonnerie.
  ///
  /// Aucun jeton n'est joint : l'adresse est celle d'un bucket public, ou du
  /// serveur qui redirige vers le stockage.
  Future<({List<int> bytes, String? contentType})?> downloadListRingtone(
    String url, {
    int maxBytes = 5 * 1024 * 1024,
  }) async {
    final response = await _client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) return null;
    if (response.bodyBytes.isEmpty || response.bodyBytes.length > maxBytes) {
      return null;
    }
    return (
      bytes: response.bodyBytes,
      contentType: response.headers['content-type'],
    );
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

  /// Déclare ce que CE téléphone sait lire : le HEVC en 720p, par une puce
  /// dédiée. Le serveur en tire, discussion par discussion, le droit d'envoyer
  /// une vidéo en HEVC (voir [conversationAllowsHevc]).
  Future<void> reportVideoCapabilities({required bool hevcDecode}) async {
    await _handleRequest(
      () => _client.put(
        Uri.parse('${TalkyApiClient.baseUrl}/users/me/video-capabilities'),
        headers: _headers,
        body: jsonEncode({'hevcDecode': hevcDecode}),
      ),
    );
  }

  /// `true` si tous les appareils actifs des membres de la discussion lisent
  /// le HEVC : une vidéo peut alors partir en HEVC, plus légère d'un tiers.
  Future<bool> conversationAllowsHevc(int conversationID) async {
    final body = await _handleRequest(
      () => _client.get(
        Uri.parse(
          '${TalkyApiClient.baseUrl}/conversations/$conversationID/video-codecs',
        ),
        headers: _headers,
      ),
    );
    return body is Map && body['hevc'] == true;
  }
}
