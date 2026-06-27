import 'dart:io';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Convertit une URL HTTP du serveur en HTTPS.
/// Le serveur redirige systématiquement HTTP → HTTPS (certificat auto-signé).
String normalizeMediaUrl(String url) {
  if (url.startsWith('http://')) return url.replaceFirst('http://', 'https://');
  return url;
}

/// CacheManager qui accepte le certificat auto-signé du serveur (IP brute).
class TlsCacheManager extends CacheManager with ImageCacheManager {
  static const _key = 'tlsCache';

  static final TlsCacheManager _instance = TlsCacheManager._internal();
  factory TlsCacheManager() => _instance;

  TlsCacheManager._internal()
      : super(Config(_key, fileService: _TlsFileService()));
}

class _TlsFileService extends HttpFileService {
  _TlsFileService() : super(httpClient: _buildClient());

  static http.Client _buildClient() {
    final inner = HttpClient()
      ..badCertificateCallback = (_, __, ___) => true;
    return IOClient(inner);
  }
}
