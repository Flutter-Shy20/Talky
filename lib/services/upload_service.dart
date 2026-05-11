import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../config/app_config.dart';

/// Service d'upload de fichiers vers le backend.
///
/// Le backend doit implémenter POST /api/upload (actuellement stub 501).
/// Quand ce sera fait, ce service fonctionnera sans modification côté Flutter.
///
/// FORMAT ATTENDU DE LA RÉPONSE :
/// { "url": "https://..." }
class UploadService {
  static final UploadService _instance = UploadService._internal();
  factory UploadService() => _instance;
  UploadService._internal();

  /// Upload des octets bruts vers le serveur.
  ///
  /// [bytes]    : contenu du fichier.
  /// [filename] : nom du fichier (ex: "photo.jpg", "voice.webm").
  /// [mimeType] : type MIME (ex: "image/jpeg", "audio/webm", "application/pdf").
  ///
  /// Retourne l'URL publique du fichier uploadé.
  Future<String> uploadBytes(
    Uint8List bytes,
    String filename,
    String mimeType,
  ) async {
    final uri = Uri.parse('${AppConfig.serverUrl}/api/upload');

    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${AppConfig.token}'
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: filename,
        ),
      );

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode == 501) {
      throw Exception(
        'L\'upload n\'est pas encore implémenté côté backend.\n'
        'Contacte l\'équipe backend pour implémenter POST /api/upload.',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Erreur upload [${response.statusCode}]');
    }

    final data = jsonDecode(response.body);
    final url = data['url'] as String?;
    if (url == null || url.isEmpty) {
      throw Exception('Le backend n\'a pas renvoyé d\'URL');
    }
    return url;
  }
}
