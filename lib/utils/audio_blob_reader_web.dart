// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:async';
import 'dart:typed_data';

/// Lit une blob URL (ex: "blob:http://localhost:5000/abc-123") et
/// retourne son contenu en bytes.
/// Utilisé sur web après _recorder.stop() qui retourne une blob URL.
Future<Uint8List> fetchBlobUrl(String blobUrl) async {
  final completer = Completer<Uint8List>();

  final xhr = html.HttpRequest();
  xhr.open('GET', blobUrl, async: true);
  xhr.responseType = 'arraybuffer';

  xhr.onLoad.first.then((_) {
    final buffer = xhr.response as ByteBuffer;
    completer.complete(buffer.asUint8List());
  });

  xhr.onError.first.then((_) {
    completer.completeError(
        Exception('Impossible de lire le blob audio : ${xhr.statusText}'));
  });

  xhr.send();
  return completer.future;
}