import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talky_flutter/core/services/list_ringtone_preferences.dart';
import 'package:talky_flutter/core/services/ringtone_preferences.dart';
import 'package:talky_flutter/talky_api_client.dart';
import 'package:talky_flutter/talky_models.dart';

/// Synchronisation des sonneries de liste entre les appareils d'un compte.
///
/// Le fil conducteur : ce qui voyage, c'est l'IDENTITÉ du son (identifiant
/// stable pour un son fourni, empreinte du contenu pour un son importé), jamais
/// le fichier ni un chemin local. Ces tests jouent le rôle de l'« appareil B »
/// qui reçoit les préférences de l'appareil A.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;

  /// Écrit un faux fichier de sonnerie et renvoie (chemin, empreinte).
  Future<({String path, String hash})> writeRingtoneFile(
    String fileName,
    String content,
  ) async {
    final file = File('${sandbox.path}/$fileName');
    await file.writeAsString(content);
    return (
      path: file.path,
      hash: sha256.convert(utf8.encode(content)).toString(),
    );
  }

  /// Installe des sonneries importées « déjà présentes sur cet appareil ».
  Future<void> seedCustomRingtones(List<Map<String, dynamic>> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'call_ringtone_custom_list',
      entries.map(jsonEncode).toList(),
    );
    RingtonePreferences.resetForTesting();
    await RingtonePreferences.preload();
  }

  ContactList listWith({
    required int idList,
    String? messageType,
    String? messageId,
    String? messageName,
    int? priority,
  }) =>
      ContactList(
        idList: idList,
        name: 'Liste $idList',
        messageSoundType: messageType,
        messageSoundId: messageId,
        messageSoundName: messageName,
        soundPriority: priority,
        // Le serveur porte bien les champs de son (migration 055 appliquée).
        soundSyncSupported: true,
      );

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('alanya_ringtones');
    SharedPreferences.setMockInitialValues({});
    RingtonePreferences.resetForTesting();
    ListRingtonePreferences.resetForTesting();
    await RingtonePreferences.preload();
    await ListRingtonePreferences.preload();
  });

  tearDown(() async {
    if (sandbox.existsSync()) await sandbox.delete(recursive: true);
  });

  group('son préinstallé', () {
    test('l’identifiant suffit : la liste sonne sur l’autre appareil', () async {
      final prefs = ListRingtonePreferences();
      await prefs.applyFromServer([
        listWith(idList: 7, messageType: 'builtin', messageId: 'notif_pop'),
      ]);

      final setting = prefs.settingFor(7);
      expect(setting.messageRingtoneId, 'notif_pop');
      expect(setting.messageSoundMissing, isFalse);

      await ListRingtonePreferences.updateMemberships({
        7: {42},
      });
      expect(ListRingtonePreferences.resolveMessage(42)?.id, 'notif_pop');
    });
  });

  group('son importé', () {
    test('même contenu → le fichier local est retrouvé par son empreinte',
        () async {
      final file = await writeRingtoneFile('MaSonnerie.mp3', 'des-octets-A');
      await seedCustomRingtones([
        {
          'id': 'custom_999',
          'label': 'MaSonnerie.mp3',
          'filePath': file.path,
          'contentHash': file.hash,
        },
      ]);

      final prefs = ListRingtonePreferences();
      await prefs.applyFromServer([
        listWith(
          idList: 1,
          messageType: 'custom',
          messageId: file.hash,
          messageName: 'MaSonnerie.mp3',
        ),
      ]);

      // L'identifiant local diffère forcément de celui de l'appareil d'origine.
      expect(prefs.settingFor(1).messageRingtoneId, 'custom_999');
      expect(prefs.settingFor(1).messageSoundMissing, isFalse);

      await ListRingtonePreferences.updateMemberships({
        1: {42},
      });
      expect(ListRingtonePreferences.resolveMessage(42)?.filePath, file.path);
    });

    test('même NOM mais contenu différent → deux sons différents', () async {
      // L'appareil B possède un « MaSonnerie.mp3 »… qui n'est pas le même.
      final autre = await writeRingtoneFile('MaSonnerie.mp3', 'des-octets-B');
      await seedCustomRingtones([
        {
          'id': 'custom_555',
          'label': 'MaSonnerie.mp3',
          'filePath': autre.path,
          'contentHash': autre.hash,
        },
      ]);

      final attendu = sha256.convert(utf8.encode('des-octets-A')).toString();
      final prefs = ListRingtonePreferences();
      await prefs.applyFromServer([
        listWith(
          idList: 1,
          messageType: 'custom',
          messageId: attendu,
          messageName: 'MaSonnerie.mp3',
        ),
      ]);

      final setting = prefs.settingFor(1);
      expect(setting.messageRingtoneId, isNull,
          reason: 'l’homonyme ne doit surtout pas servir de remplaçant');
      expect(setting.messageSoundMissing, isTrue);
      // La préférence, elle, est conservée telle quelle.
      expect(setting.messageSound?.id, attendu);

      await ListRingtonePreferences.updateMemberships({
        1: {42},
      });
      // null = « rien de particulier » → l'appelant joue son son habituel.
      expect(ListRingtonePreferences.resolveMessage(42), isNull);
    });

    test('fichier absent : la préférence survit et le son de remplacement joue',
        () async {
      final prefs = ListRingtonePreferences();
      await prefs.applyFromServer([
        listWith(
          idList: 1,
          messageType: 'custom',
          messageId: 'a' * 64,
          messageName: 'MaSonnerie.mp3',
        ),
      ]);

      expect(prefs.settingFor(1).messageSoundMissing, isTrue);

      // Redémarrage de l'app : la préférence est toujours là.
      ListRingtonePreferences.resetForTesting();
      await ListRingtonePreferences.preload();
      final apres = ListRingtonePreferences().settingFor(1);
      expect(apres.messageSound?.id, 'a' * 64);
      expect(apres.messageSound?.name, 'MaSonnerie.mp3');
    });

    test('import ultérieur du bon fichier → rebranchement sans intervention',
        () async {
      final prefs = ListRingtonePreferences();
      final futur = await writeRingtoneFile('MaSonnerie.mp3', 'des-octets-A');
      await prefs.applyFromServer([
        listWith(
          idList: 1,
          messageType: 'custom',
          messageId: futur.hash,
          messageName: 'MaSonnerie.mp3',
        ),
      ]);
      expect(prefs.settingFor(1).messageSoundMissing, isTrue);

      // L'utilisateur importe enfin le fichier attendu sur cet appareil.
      await seedCustomRingtones([
        {
          'id': 'custom_777',
          'label': 'MaSonnerie.mp3',
          'filePath': futur.path,
          'contentHash': futur.hash,
        },
      ]);
      await prefs.rebindCustomSounds();

      expect(prefs.settingFor(1).messageRingtoneId, 'custom_777');
      expect(prefs.settingFor(1).messageSoundMissing, isFalse);
    });

    test('plusieurs listes, plusieurs sons importés indépendants', () async {
      final a = await writeRingtoneFile('a.mp3', 'contenu-A');
      final b = await writeRingtoneFile('b.mp3', 'contenu-B');
      await seedCustomRingtones([
        {
          'id': 'custom_a',
          'label': 'a.mp3',
          'filePath': a.path,
          'contentHash': a.hash,
        },
        {
          'id': 'custom_b',
          'label': 'b.mp3',
          'filePath': b.path,
          'contentHash': b.hash,
        },
      ]);

      final prefs = ListRingtonePreferences();
      await prefs.applyFromServer([
        listWith(idList: 1, messageType: 'custom', messageId: a.hash),
        listWith(idList: 2, messageType: 'custom', messageId: b.hash),
        listWith(idList: 3, messageType: 'custom', messageId: 'c' * 64),
      ]);

      expect(prefs.settingFor(1).messageRingtoneId, 'custom_a');
      expect(prefs.settingFor(2).messageRingtoneId, 'custom_b');
      expect(prefs.settingFor(3).messageSoundMissing, isTrue);
    });
  });

  group('serveur pas encore à jour', () {
    test('des listes sans champs de son n’effacent aucun réglage local',
        () async {
      final file = await writeRingtoneFile('perso.mp3', 'contenu');
      await seedCustomRingtones([
        {
          'id': 'custom_1',
          'label': 'perso.mp3',
          'filePath': file.path,
          'contentHash': file.hash,
        },
      ]);

      final prefs = ListRingtonePreferences();
      await prefs.setRingtone(5, messageRingtoneId: 'custom_1');

      // Réponse d'un backend sans la migration 055 : aucune clé `*Sound*`.
      await prefs.applyFromServer([
        ContactList.fromJson({'idList': 5, 'name': 'Famille'}),
      ]);

      expect(prefs.settingFor(5).messageRingtoneId, 'custom_1');
      expect(prefs.settingFor(5).messageSound?.id, file.hash);
    });
  });

  group('ordre de priorité', () {
    test('un contact multi-listes suit l’ordre reçu du compte', () async {
      final prefs = ListRingtonePreferences();
      await prefs.applyFromServer([
        listWith(
          idList: 1,
          messageType: 'builtin',
          messageId: 'notif_pop',
          priority: 1,
        ),
        listWith(
          idList: 2,
          messageType: 'builtin',
          messageId: 'notif_ping',
          priority: 0,
        ),
      ]);

      expect(prefs.priority, [2, 1]);
      await ListRingtonePreferences.updateMemberships({
        1: {42},
        2: {42},
      });
      expect(ListRingtonePreferences.resolveMessage(42)?.id, 'notif_ping');
    });
  });

  group('hors connexion', () {
    test('le choix local reste jouable sans serveur ni réseau', () async {
      final file = await writeRingtoneFile('perso.mp3', 'contenu');
      await seedCustomRingtones([
        {
          'id': 'custom_1',
          'label': 'perso.mp3',
          'filePath': file.path,
          'contentHash': file.hash,
        },
      ]);

      // Aucune API injectée : la poussée est impossible, le réglage doit
      // néanmoins être enregistré et utilisable.
      final prefs = ListRingtonePreferences();
      await prefs.setRingtone(5, messageRingtoneId: 'custom_1');

      await ListRingtonePreferences.updateMemberships({
        5: {42},
      });
      expect(ListRingtonePreferences.resolveMessage(42)?.filePath, file.path);

      // Et il survit au redémarrage, avec son identité synchronisable.
      ListRingtonePreferences.resetForTesting();
      await ListRingtonePreferences.preload();
      final apres = ListRingtonePreferences().settingFor(5);
      expect(apres.messageSound?.type, ListSoundType.custom);
      expect(apres.messageSound?.id, file.hash);
      expect(apres.messageSound?.name, 'perso.mp3');
    });
  });

  // ── Fichiers des sons importés ─────────────────────────────────────
  // L'identité voyage avec la liste ; le fichier, lui, est déposé par
  // l'appareil qui l'a importé et récupéré par les autres.
  group('fichier du son importé', () {
    late List<http.Request> requetes;

    TalkyApiClient apiAvec(
      Future<http.Response> Function(http.Request req) repondre,
    ) =>
        TalkyApiClient(client: MockClient((req) async {
          requetes.add(req);
          return repondre(req);
        }));

    ContactList listeImportee(int idList, String hash, {String? url}) =>
        ContactList(
          idList: idList,
          name: 'Liste $idList',
          messageSoundType: 'custom',
          messageSoundId: hash,
          messageSoundName: 'MaSonnerie.mp3',
          messageSoundUrl: url,
          soundSyncSupported: true,
        );

    setUp(() => requetes = []);

    Future<({String path, String hash})> sonnerieLocale() async {
      final f = await writeRingtoneFile('MaSonnerie.mp3', 'des-octets-A');
      await seedCustomRingtones([
        {
          'id': 'custom_1',
          'label': 'MaSonnerie.mp3',
          'filePath': f.path,
          'contentHash': f.hash,
        },
      ]);
      return f;
    }

    test('importé ici : déposé une fois, par ticket puis envoi direct', () async {
      final f = await sonnerieLocale();
      final api = apiAvec((req) async {
        if (req.url.path.endsWith('/upload/ticket')) {
          return http.Response(
            jsonEncode({
              'mode': 'direct',
              'method': 'PUT',
              'uploadUrl': 'https://profilemedia.s3.example/ringtones/12/jeton?sig=1',
              'headers': {'Content-Type': 'audio/mpeg'},
              'url': 'https://profilemedia.s3.example/ringtones/12/jeton',
            }),
            200,
          );
        }
        if (req.method == 'PUT') return http.Response('', 200);
        return http.Response('inattendu', 500);
      });
      final prefs = ListRingtonePreferences(api: api);

      await prefs.applyFromServer([listeImportee(1, f.hash)]);
      await ListRingtonePreferences.pendingFileSync;

      final ticket = requetes.firstWhere((r) => r.url.path.endsWith('/upload/ticket'));
      expect(jsonDecode(ticket.body), {
        'kind': 'ringtone',
        'sha256': f.hash,
        'mimetype': 'audio/mpeg',
        'size': 'des-octets-A'.length,
      });
      final envoi = requetes.singleWhere((r) => r.method == 'PUT');
      expect(envoi.bodyBytes, utf8.encode('des-octets-A'));
      expect(envoi.headers['Content-Type'], 'audio/mpeg');

      // Synchronisation suivante : déjà déposé, aucune nouvelle requête.
      requetes.clear();
      await prefs.applyFromServer([listeImportee(1, f.hash)]);
      await ListRingtonePreferences.pendingFileSync;
      expect(requetes.where((r) => r.url.path.endsWith('/upload/ticket')), isEmpty);
    });

    test('déjà sur le serveur, ou serveur qui ne les garde pas : rien n’est envoyé', () async {
      final f = await sonnerieLocale();
      for (final mode in ['exists', 'unavailable']) {
        ListRingtonePreferences.resetForTesting();
        await ListRingtonePreferences.preload();
        requetes.clear();
        final api = apiAvec((req) async => http.Response(
              jsonEncode({'mode': mode, 'url': 'https://profilemedia.s3.example/r'}),
              200,
            ));
        final prefs = ListRingtonePreferences(api: api);
        await prefs.applyFromServer([listeImportee(1, f.hash)]);
        await ListRingtonePreferences.pendingFileSync;
        expect(requetes.where((r) => r.method == 'PUT'), isEmpty, reason: mode);
      }
    });

    test('absent ici : téléchargé, vérifié, puis la liste se rebranche', () async {
      final attendu = await writeRingtoneFile('MaSonnerie.mp3', 'des-octets-B');
      const url = 'https://profilemedia.s3.example/ringtones/12/jeton';
      final api = apiAvec((req) async {
        if (req.method == 'GET' && req.url.toString() == url) {
          return http.Response.bytes(
            utf8.encode('des-octets-B'),
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        }
        return http.Response('', 404);
      });
      final importes = <Map<String, Object>>[];
      final prefs = ListRingtonePreferences(
        api: api,
        importer: ({
          required List<int> bytes,
          required String extension,
          required String label,
          required String expectedHash,
        }) async {
          importes.add({
            'bytes': utf8.decode(bytes),
            'extension': extension,
            'label': label,
            'hash': expectedHash,
          });
          // Ce que ferait l'import réel : la sonnerie existe désormais ici.
          await seedCustomRingtones([
            {
              'id': 'custom_recue',
              'label': label,
              'filePath': attendu.path,
              'contentHash': expectedHash,
            },
          ]);
          return RingtonePreferences.customByContentHash(expectedHash);
        },
      );

      await prefs.applyFromServer([listeImportee(1, attendu.hash, url: url)]);
      expect(prefs.settingFor(1).messageSoundMissing, isTrue);
      await ListRingtonePreferences.pendingFileSync;

      expect(importes, [
        {
          'bytes': 'des-octets-B',
          'extension': 'mp3',
          'label': 'MaSonnerie.mp3',
          'hash': attendu.hash,
        },
      ]);
      expect(prefs.settingFor(1).messageRingtoneId, 'custom_recue');
      expect(prefs.settingFor(1).messageSoundMissing, isFalse);
    });

    test('fichier introuvable : une seule tentative par session', () async {
      const url = 'https://profilemedia.s3.example/ringtones/12/absent';
      final api = apiAvec((req) async => http.Response('', 404));
      final prefs = ListRingtonePreferences(api: api);

      await prefs.applyFromServer([listeImportee(1, 'c' * 64, url: url)]);
      await ListRingtonePreferences.pendingFileSync;
      await prefs.applyFromServer([listeImportee(1, 'c' * 64, url: url)]);
      await ListRingtonePreferences.pendingFileSync;

      expect(requetes.where((r) => r.method == 'GET'), hasLength(1));
      expect(prefs.settingFor(1).messageSoundMissing, isTrue);
    });

    test('contenu qui ne correspond pas à l’empreinte : refusé', () async {
      final option = await RingtonePreferences.importSynced(
        bytes: utf8.encode('autre-chose'),
        extension: 'mp3',
        label: 'MaSonnerie.mp3',
        expectedHash: sha256.convert(utf8.encode('des-octets-A')).toString(),
      );
      expect(option, isNull);
    });

    test('extension : d’après le type annoncé, sinon le nom', () {
      expect(RingtonePreferences.extensionForSynced(contentType: 'audio/mpeg'), 'mp3');
      expect(RingtonePreferences.extensionForSynced(contentType: 'audio/mp4; x=1'), 'm4a');
      expect(RingtonePreferences.extensionForSynced(contentType: 'application/octet-stream', name: 'a.ogg'), 'ogg');
      expect(RingtonePreferences.extensionForSynced(contentType: 'image/png', name: 'a.flac'), isNull);
    });
  });
}
