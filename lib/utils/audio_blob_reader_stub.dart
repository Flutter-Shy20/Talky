import 'dart:typed_data';

/// Stub non-web — jamais appelé sur mobile/desktop.
/// Sur ces plateformes on lit directement le fichier avec dart:io.
Future<Uint8List> fetchBlobUrl(String blobUrl) async {
  throw UnsupportedError('fetchBlobUrl est uniquement disponible sur web.');
}