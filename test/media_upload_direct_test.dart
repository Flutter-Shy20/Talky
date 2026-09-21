import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:talky_flutter/talky_api_client.dart';

const _cacheImmuable = 'public, max-age=31536000, immutable';

Map<String, dynamic> _ticketDirect() => {
      'mode': 'direct',
      'method': 'PUT',
      'uploadUrl': 'https://alanyaprivate.s3.eu-central-003.backblazeb2.com'
          '/media/2026-09-15/video/media_1_2_abc.mp4?X-Amz-Signature=sig',
      'headers': {'Content-Type': 'video/mp4', 'Cache-Control': _cacheImmuable},
      'expiresIn': 900,
      'url': 'https://www.alanya237.com/uploads/media/2026-09-15/video/media_1_2_abc.mp4',
      'filename': 'media_1_2_abc.mp4',
      'mimetype': 'video/mp4',
      'size': 4096,
      'msgType': 2,
    };

void main() {
  late Directory tmp;
  late File video;
  late List<http.Request> requests;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('upload_direct_');
    video = File(p.join(tmp.path, 'clip.mp4'))
      ..writeAsBytesSync(List<int>.generate(4096, (i) => i % 256));
    requests = [];
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  TalkyApiClient apiWith(Future<http.Response> Function(http.Request req) handler) =>
      TalkyApiClient(client: MockClient((req) async {
        requests.add(req);
        return handler(req);
      }));

  test('ticket direct : le fichier part au stockage, en-têtes signés à l’identique', () async {
    final api = apiWith((req) async {
      if (req.url.path.endsWith('/upload/ticket')) {
        return http.Response(jsonEncode(_ticketDirect()), 200);
      }
      if (req.method == 'PUT') return http.Response('', 200);
      return http.Response('inattendu', 500);
    });
    final progress = <double>[];

    final res = await api.uploadMedia(video, onProgress: progress.add);

    expect(requests.map((r) => r.method), ['POST', 'PUT']);
    expect(jsonDecode(requests.first.body), {
      'kind': 'media',
      'mimetype': 'video/mp4',
      'size': 4096,
      'fileName': 'clip.mp4',
    });
    final put = requests.last;
    expect(put.url.host, 'alanyaprivate.s3.eu-central-003.backblazeb2.com');
    expect(put.headers['content-type'], 'video/mp4');
    expect(put.headers['cache-control'], _cacheImmuable);
    expect(put.headers.containsKey('authorization'), isFalse,
        reason: 'le jeton de l’API ne part jamais chez le stockage');
    expect(put.bodyBytes, video.readAsBytesSync());
    expect(progress.last, 1.0);
    expect(res['url'], _ticketDirect()['url']);
    expect(res['msgType'], 2);
    expect(res['originalName'], 'clip.mp4');
  });

  test('mode multipart : envoi par formulaire, comme avant', () async {
    final api = apiWith((req) async {
      if (req.url.path.endsWith('/upload/ticket')) {
        return http.Response(jsonEncode({'mode': 'multipart'}), 200);
      }
      return http.Response(jsonEncode({'url': 'https://x/uploads/media/a.mp4', 'msgType': 2}), 200);
    });

    final res = await api.uploadMedia(video);

    expect(requests, hasLength(2));
    expect(requests.last.method, 'POST');
    expect(requests.last.url.path, endsWith('/upload/media'));
    expect(requests.last.headers['content-type'], startsWith('multipart/form-data'));
    expect(res['url'], 'https://x/uploads/media/a.mp4');
  });

  test('serveur sans route de ticket (404) : repli sur le formulaire', () async {
    final api = apiWith((req) async {
      if (req.url.path.endsWith('/upload/ticket')) return http.Response('Not Found', 404);
      return http.Response(jsonEncode({'url': 'https://x/uploads/media/a.mp4'}), 200);
    });

    final res = await api.uploadMedia(video);

    expect(requests.last.url.path, endsWith('/upload/media'));
    expect(res['url'], 'https://x/uploads/media/a.mp4');
  });

  test('ticket refusé (413) : aucun octet envoyé, erreur remontée avec son statut', () async {
    final api = apiWith((req) async => http.Response(
          jsonEncode({'error': 'Fichier trop volumineux', 'code': 'FILE_TOO_LARGE'}),
          413,
        ));

    await expectLater(
      api.uploadMedia(video),
      throwsA(isA<TalkyException>().having((e) => e.statusCode, 'statusCode', 413)),
    );
    expect(requests, hasLength(1));
  });

  test('refus du stockage (403) : erreur remontée avec son statut', () async {
    final api = apiWith((req) async {
      if (req.url.path.endsWith('/upload/ticket')) {
        return http.Response(jsonEncode(_ticketDirect()), 200);
      }
      return http.Response('<Error><Code>AccessDenied</Code></Error>', 403);
    });

    await expectLater(
      api.uploadMedia(video),
      throwsA(isA<TalkyException>().having((e) => e.statusCode, 'statusCode', 403)),
    );
  });

  test('avatar : ticket de type avatar, repli sur /upload/avatar', () async {
    final photo = File(p.join(tmp.path, 'me.jpg'))..writeAsBytesSync([1, 2, 3]);
    final api = apiWith((req) async {
      if (req.url.path.endsWith('/upload/ticket')) {
        return http.Response(jsonEncode({'mode': 'multipart'}), 200);
      }
      return http.Response(jsonEncode({'url': 'https://x/uploads/images/img.jpg'}), 200);
    });

    await api.uploadImage(photo);

    expect(jsonDecode(requests.first.body)['kind'], 'avatar');
    expect(jsonDecode(requests.first.body)['mimetype'], 'image/jpeg');
    expect(requests.last.url.path, endsWith('/upload/avatar'));
  });
}
