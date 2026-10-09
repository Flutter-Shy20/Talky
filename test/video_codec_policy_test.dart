import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/video_codec_policy.dart';

const _encodes = VideoCodecSupport(hevcEncoder: true, hevcDecoder: true);
const _readsOnly = VideoCodecSupport(hevcEncoder: false, hevcDecoder: true);

void main() {
  late List<int> asked;
  late List<bool> reported;
  late bool serverSays;
  late Object? serverError;
  late DateTime now;

  VideoCodecPolicy build({VideoCodecSupport support = _encodes}) => VideoCodecPolicy(
        fetchAllowsHevc: (id) async {
          asked.add(id);
          if (serverError != null) throw serverError!;
          return serverSays;
        },
        sendCapabilities: ({required bool hevcDecode}) async {
          if (serverError != null) throw serverError!;
          reported.add(hevcDecode);
        },
        support: () async => support,
        clock: () => now,
      );

  setUp(() {
    asked = [];
    reported = [];
    serverSays = true;
    serverError = null;
    now = DateTime(2026, 10, 8, 12);
  });

  group('allowsHevc', () {
    test('le serveur confirme et ce téléphone encode : HEVC', () async {
      expect(await build().allowsHevc(10), isTrue);
      expect(asked, [10]);
    });

    test('ce téléphone n’encode pas le HEVC : H.264, sans rien demander', () async {
      expect(await build(support: _readsOnly).allowsHevc(10), isFalse);
      expect(asked, isEmpty);
    });

    test('un appareil de la discussion ne lit pas le HEVC : H.264', () async {
      serverSays = false;
      expect(await build().allowsHevc(10), isFalse);
    });

    test('réseau absent ou serveur antérieur : H.264', () async {
      serverError = Exception('hors ligne');
      expect(await build().allowsHevc(10), isFalse);
    });

    test('réponse réutilisée dix minutes, puis redemandée', () async {
      final policy = build();
      await policy.allowsHevc(10);
      now = now.add(const Duration(minutes: 9));
      await policy.allowsHevc(10);
      expect(asked, [10], reason: 'encore en cache');
      now = now.add(const Duration(minutes: 2));
      await policy.allowsHevc(10);
      expect(asked, [10, 10], reason: 'un nouveau membre a pu arriver');
    });

    test('déconnexion : le compte suivant redemande', () async {
      final policy = build();
      await policy.allowsHevc(10);
      policy.reset();
      await policy.allowsHevc(10);
      expect(asked, [10, 10]);
    });
  });

  group('reportCapabilities', () {
    test('déclaré une fois par session', () async {
      final policy = build();
      await policy.reportCapabilities();
      await policy.reportCapabilities();
      expect(reported, [true]);
    });

    test('un échec sera retenté au prochain appel', () async {
      final policy = build();
      serverError = Exception('hors ligne');
      await policy.reportCapabilities();
      expect(reported, isEmpty);
      serverError = null;
      await policy.reportCapabilities();
      expect(reported, [true]);
    });

    test('après déconnexion, le compte suivant redéclare', () async {
      final policy = build(support: _readsOnly);
      await policy.reportCapabilities();
      policy.reset();
      await policy.reportCapabilities();
      expect(reported, [true, true], reason: 'un iPhone lit le HEVC sans l’encoder');
    });
  });

  test('l’instance créée au démarrage sert les services sans contexte', () async {
    final policy = build();
    expect(VideoCodecPolicy.maybeInstance, same(policy));
    expect(await hevcAllowedFor(10), isTrue);
  });
}
