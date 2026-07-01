// Signal Protocol implementation : X3DH + Double Ratchet + persistance SQLite (F1+F2)
//
// F1 : génération d'identité (IK_DH, IK_Sign, SPK, OTPKs), X3DH, Double Ratchet.
// F2 : chaque état de session et chaque OTPK sont persistés dans AppDatabase via
//      SignalStore. L'application peut redémarrer sans perdre les sessions actives.

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../talky_api_client.dart';
import '../db/app_database.dart';
import '../db/signal_store.dart';

// ── Wire type ──────────────────────────────────────────────────────────────

/// Payload chiffré prêt à diffuser via le socket `message:send`.
class E2eePayload {
  final String ciphertext; // base64(cipherText || mac_16bytes)
  final String nonce;      // base64 12-byte AES-GCM nonce
  final Map<String, dynamic> header;

  const E2eePayload({
    required this.ciphertext,
    required this.nonce,
    required this.header,
  });

  Map<String, dynamic> toSocketMap() => {
    'ciphertext': ciphertext,
    'nonce': nonce,
    'header': jsonEncode(header),
  };
}

// ── Types internes ─────────────────────────────────────────────────────────

class _Identity {
  final SimpleKeyPair ikDh;
  final SimpleKeyPair ikSign;
  final SimpleKeyPair spk;
  final List<int> spkSig;
  final int spkId;
  final int registrationId;
  final List<({int id, SimpleKeyPair kp})> otpks;

  _Identity({
    required this.ikDh,
    required this.ikSign,
    required this.spk,
    required this.spkSig,
    required this.spkId,
    required this.registrationId,
    required this.otpks,
  });
}

class _DrState {
  SecretKey rk;
  SecretKey? cks;
  SecretKey? ckr;
  SimpleKeyPair dhS;
  SimplePublicKey? dhR;
  int ns = 0;
  int nr = 0;
  int pn = 0;
  Map<String, List<int>> skipped = {};
  Map<String, dynamic>? x3dhHeader;

  _DrState({
    required this.rk,
    required this.cks,
    required this.ckr,
    required this.dhS,
    required this.dhR,
    this.x3dhHeader,
  });
}

// ── Service ────────────────────────────────────────────────────────────────

const int _maxSkip = 500;

class E2eeService {
  static const _kIkDh   = 'talky_ik_dh_';
  static const _kIkSign = 'talky_ik_sign_';
  static const _kSpk    = 'talky_spk_';
  static const _kSpkId  = 'talky_spk_id_';
  static const _kRegId  = 'talky_reg_id_';

  final TalkyApiClient _api;
  final FlutterSecureStorage _secure;
  final SignalStore? _store; // null si pas de base de données disponible

  int _myId = 0;
  _Identity? _identity;

  final Map<int, _DrState> _sessions = {};
  final Map<int, ({int id, SimpleKeyPair kp})> _pendingOtpks = {};

  E2eeService(this._api, {AppDatabase? db})
      : _secure = const FlutterSecureStorage(),
        _store = db != null ? SignalStore(db) : null;

  bool get isReady => _identity != null && _myId != 0;

  /// Clé d'identité DH (X25519) publique en base64 — pour la vérification des clés.
  Future<String?> getIdentityFingerprint() async {
    if (_identity == null) return null;
    final pub = await _identity!.ikDh.extractPublicKey();
    return base64Encode(pub.bytes);
  }

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> init(int userId) async {
    _myId = userId;
    _sessions.clear();
    _pendingOtpks.clear();

    _identity = await _loadOrGenerate(userId);

    // Charger les OTPKs persistées (F2)
    await _loadOtpksFromStore();

    try {
      await _uploadBundle();
    } catch (e) {
      debugPrint('[E2EE] upload bundle différé: $e');
    }
  }

  Future<_Identity> _loadOrGenerate(int userId) async {
    final exists = await _secure.read(key: '$_kIkDh$userId');
    return exists != null ? _load(userId) : _generateAndSave(userId);
  }

  Future<_Identity> _generateAndSave(int userId) async {
    final rng = Random.secure();

    final ikDh   = await X25519().newKeyPair();
    final ikSign = await Ed25519().newKeyPair();
    final spk    = await X25519().newKeyPair();
    final spkId  = rng.nextInt(0xFFFF);
    final regId  = 1 + rng.nextInt(16382);

    final spkPub = await spk.extractPublicKey();
    final sig    = await Ed25519().sign(spkPub.bytes, keyPair: ikSign);

    await Future.wait([
      _secure.write(
          key: '$_kIkDh$userId',
          value: base64Encode(await ikDh.extractPrivateKeyBytes())),
      _secure.write(
          key: '$_kIkSign$userId',
          value: base64Encode(await ikSign.extractPrivateKeyBytes())),
      _secure.write(
          key: '$_kSpk$userId',
          value: base64Encode(await spk.extractPrivateKeyBytes())),
      _secure.write(key: '$_kSpkId$userId', value: spkId.toString()),
      _secure.write(key: '$_kRegId$userId', value: regId.toString()),
    ]);

    return _Identity(
      ikDh: ikDh, ikSign: ikSign, spk: spk,
      spkSig: sig.bytes, spkId: spkId, registrationId: regId,
      otpks: await _genOtpks(10),
    );
  }

  Future<_Identity> _load(int userId) async {
    Future<SimpleKeyPair> x(String k) async =>
        X25519().newKeyPairFromSeed(
            base64Decode(await _secure.read(key: k) ?? ''));
    Future<SimpleKeyPair> ed(String k) async =>
        Ed25519().newKeyPairFromSeed(
            base64Decode(await _secure.read(key: k) ?? ''));

    final ikDh   = await x('$_kIkDh$userId');
    final ikSign = await ed('$_kIkSign$userId');
    final spk    = await x('$_kSpk$userId');
    final spkId  = int.parse(await _secure.read(key: '$_kSpkId$userId') ?? '0');
    final regId  = int.parse(await _secure.read(key: '$_kRegId$userId') ?? '0');

    final spkPub = await spk.extractPublicKey();
    final sig    = await Ed25519().sign(spkPub.bytes, keyPair: ikSign);

    // Les OTPKs en mémoire seront rechargées depuis le store juste après.
    return _Identity(
      ikDh: ikDh, ikSign: ikSign, spk: spk,
      spkSig: sig.bytes, spkId: spkId, registrationId: regId,
      otpks: [],
    );
  }

  Future<List<({int id, SimpleKeyPair kp})>> _genOtpks(int n) async {
    final rng = Random.secure();
    return Future.wait(List.generate(n, (_) async {
      return (id: rng.nextInt(0xFFFF), kp: await X25519().newKeyPair());
    }));
  }

  // ── Persistance OTPKs ─────────────────────────────────────────────────────

  Future<void> _loadOtpksFromStore() async {
    if (_store == null) return;
    final rows = await _store.loadAllOtpks(_myId);
    for (final row in rows) {
      final kp = await X25519().newKeyPairFromSeed(row.privBytes);
      _pendingOtpks[row.otpkId] = (id: row.otpkId, kp: kp);
    }
  }

  Future<void> _persistOtpks(
      List<({int id, SimpleKeyPair kp})> otpks) async {
    if (_store == null) return;
    await _store.clearOtpks(_myId);
    for (final o in otpks) {
      final priv = Uint8List.fromList(await o.kp.extractPrivateKeyBytes());
      await _store.storeOtpk(_myId, o.id, priv);
    }
  }

  // ── Upload bundle ─────────────────────────────────────────────────────────

  Future<void> _uploadBundle() async {
    final id = _identity!;

    // Si on a chargé depuis secure_storage (reconnexion), les otpks du store
    // sont déjà en mémoire dans _pendingOtpks. On n'en génère de nouvelles
    // que si le stock est vide.
    List<({int id, SimpleKeyPair kp})> otpksToUpload = id.otpks.isNotEmpty
        ? id.otpks
        : _pendingOtpks.values.toList();

    if (otpksToUpload.isEmpty) {
      otpksToUpload = await _genOtpks(10);
    }

    final ikDhPub   = await id.ikDh.extractPublicKey();
    final ikSignPub = await id.ikSign.extractPublicKey();
    final spkPub    = await id.spk.extractPublicKey();

    final otpkList = await Future.wait(otpksToUpload.map((e) async => {
      'keyId': e.id,
      'publicKey': base64Encode((await e.kp.extractPublicKey()).bytes),
    }));

    await _api.uploadBundle({
      'registrationId':  id.registrationId,
      'identityKeyDh':   base64Encode(ikDhPub.bytes),
      'identityKeySign': base64Encode(ikSignPub.bytes),
      'signedPrekey': {
        'keyId':     id.spkId,
        'publicKey': base64Encode(spkPub.bytes),
        'signature': base64Encode(id.spkSig),
      },
      'oneTimePreKeys': otpkList,
    });

    // Persistance F2 : sauvegarder les OTPKs dans SQLite
    _pendingOtpks.clear();
    for (final o in otpksToUpload) {
      _pendingOtpks[o.id] = o;
    }
    await _persistOtpks(otpksToUpload);
  }

  // ── X3DH outgoing ─────────────────────────────────────────────────────────

  Future<_DrState> _buildOutgoing(int recipientId) async {
    final id     = _identity!;
    final bundle = await _api.fetchKeyBundle(recipientId);

    final ikBDhBytes   = base64Decode(bundle['identityKeyDh']             as String);
    final ikBSignBytes = base64Decode(bundle['identityKeySign']           as String);
    final spkBBytes    = base64Decode(bundle['signedPrekey']['publicKey'] as String);
    final spkBSig      = base64Decode(bundle['signedPrekey']['signature'] as String);
    final spkBId       = bundle['signedPrekey']['keyId'] as int;

    final ikBSignPub = SimplePublicKey(ikBSignBytes, type: KeyPairType.ed25519);
    final valid = await Ed25519().verify(
      spkBBytes,
      signature: Signature(spkBSig, publicKey: ikBSignPub),
    );
    if (!valid) throw StateError('[E2EE] SPK invalide pour $recipientId');

    final ikBDhPub = SimplePublicKey(ikBDhBytes, type: KeyPairType.x25519);
    final spkBPub  = SimplePublicKey(spkBBytes,  type: KeyPairType.x25519);

    SimplePublicKey? otpkBPub;
    int? otpkBId;
    if (bundle['prekey'] != null) {
      otpkBPub = SimplePublicKey(
          base64Decode(bundle['prekey']['publicKey'] as String),
          type: KeyPairType.x25519);
      otpkBId = bundle['prekey']['keyId'] as int;
    }

    final ekKp  = await X25519().newKeyPair();
    final ekPub = await ekKp.extractPublicKey();

    final dhList = [
      await _dh(id.ikDh, spkBPub),
      await _dh(ekKp,    ikBDhPub),
      await _dh(ekKp,    spkBPub),
      if (otpkBPub != null) await _dh(ekKp, otpkBPub),
    ];
    final sk = await _x3dhKdf(dhList);

    final dhSKp     = await X25519().newKeyPair();
    final (rk, cks) = await _kdfRk(sk, await _dh(dhSKp, spkBPub));

    final dhSPub   = await dhSKp.extractPublicKey();
    final ikADhPub = await id.ikDh.extractPublicKey();

    return _DrState(
      rk: rk, cks: cks, ckr: null,
      dhS: dhSKp, dhR: spkBPub,
      x3dhHeader: {
        'type':   'prekey',
        'ek':     base64Encode(ekPub.bytes),
        'ik':     base64Encode(ikADhPub.bytes),
        'spk_id': spkBId,
        'dh':     base64Encode(dhSPub.bytes),
        if (otpkBId != null) 'opk_id': otpkBId,
      },
    );
  }

  // ── X3DH incoming ─────────────────────────────────────────────────────────

  Future<_DrState> _buildIncoming(
      int senderId, Map<String, dynamic> header) async {
    final id = _identity!;

    final ekAPub   = SimplePublicKey(
        base64Decode(header['ek'] as String), type: KeyPairType.x25519);
    final ikADhPub = SimplePublicKey(
        base64Decode(header['ik'] as String), type: KeyPairType.x25519);
    final aliceDrPub = SimplePublicKey(
        base64Decode(header['dh'] as String), type: KeyPairType.x25519);

    SimpleKeyPair? otpkKp;
    final otpkId = header['opk_id'] as int?;
    if (otpkId != null) {
      otpkKp = _pendingOtpks.remove(otpkId)?.kp;
      // Supprimer du store (one-time = usage unique)
      if (_store != null) await _store.deleteOtpk(_myId, otpkId);
    }

    final dhList = [
      await _dh(id.spk,  ikADhPub),
      await _dh(id.ikDh, ekAPub),
      await _dh(id.spk,  ekAPub),
      if (otpkKp != null) await _dh(otpkKp, ekAPub),
    ];
    final sk = await _x3dhKdf(dhList);

    final (rk, ckr) = await _kdfRk(sk, await _dh(id.spk, aliceDrPub));

    return _DrState(
      rk: rk, cks: null, ckr: ckr,
      dhS: await X25519().newKeyPair(),
      dhR: aliceDrPub,
    );
  }

  // ── Chiffrement ───────────────────────────────────────────────────────────

  Future<E2eePayload?> encrypt(int recipientId, String plaintext) async {
    if (!isReady) return null;
    try {
      final state = await _getOrBuildOutgoing(recipientId);

      if (state.cks == null) {
        debugPrint('[E2EE] encrypt: CKs absent pour $recipientId');
        return null;
      }

      final (newCks, mk) = await _kdfCk(state.cks!);
      state.cks = newCks;

      final dhSPub = await state.dhS.extractPublicKey();
      final header = <String, dynamic>{
        if (state.x3dhHeader != null) ...state.x3dhHeader!,
        'dh': base64Encode(dhSPub.bytes),
        'n':  state.ns,
        'pn': state.pn,
        if (state.x3dhHeader == null) 'type': 'normal',
      };
      state.ns++;

      final (ct, nonce) = await _aesgcmEncrypt(mk, utf8.encode(plaintext));

      // Persistance F2
      await _saveSession(recipientId, state);

      return E2eePayload(
        ciphertext: base64Encode(ct),
        nonce: base64Encode(nonce),
        header: header,
      );
    } catch (e) {
      debugPrint('[E2EE] encrypt échoué ($recipientId): $e');
      return null;
    }
  }

  // ── Déchiffrement ─────────────────────────────────────────────────────────

  Future<String?> decrypt(
      int senderId, String ciphertextB64, String nonceB64,
      Map<String, dynamic> header) async {
    if (!isReady) return null;
    try {
      final state = await _getOrBuildIncoming(senderId, header);

      final dhPubBytes = base64Decode(header['dh'] as String);
      final dhPub      = SimplePublicKey(dhPubBytes, type: KeyPairType.x25519);
      final msgN       = header['n'] as int;
      final msgPn      = header['pn'] as int;

      // Clé de message sautée ?
      final skipKey = '${base64Encode(dhPubBytes)}:$msgN';
      if (state.skipped.containsKey(skipKey)) {
        final mk = SecretKey(state.skipped.remove(skipKey)!);
        await _saveSession(senderId, state);
        return _aesgcmDecrypt(mk, base64Decode(ciphertextB64), base64Decode(nonceB64));
      }

      if (state.dhR == null || !_pubEq(dhPub, state.dhR!)) {
        await _skipMsgKeys(state, msgPn);
        await _dhRatchet(state, dhPub);
      }

      await _skipMsgKeys(state, msgN);
      if (state.ckr == null) throw StateError('CKr absent');
      final (newCkr, mk) = await _kdfCk(state.ckr!);
      state.ckr = newCkr;
      state.nr++;

      // Persistance F2
      await _saveSession(senderId, state);

      return await _aesgcmDecrypt(
          mk, base64Decode(ciphertextB64), base64Decode(nonceB64));
    } catch (e) {
      debugPrint('[E2EE] decrypt échoué ($senderId): $e');
      return null;
    }
  }

  // ── Gestion des sessions (mémoire + store) ────────────────────────────────

  Future<_DrState> _getOrBuildOutgoing(int recipientId) async {
    if (_sessions.containsKey(recipientId)) return _sessions[recipientId]!;

    // Essayer depuis le store persistant
    final persisted = await _loadSession(recipientId);
    if (persisted != null) {
      _sessions[recipientId] = persisted;
      return persisted;
    }

    // Nouvelle session X3DH
    final state = await _buildOutgoing(recipientId);
    _sessions[recipientId] = state;
    await _saveSession(recipientId, state);
    return state;
  }

  Future<_DrState> _getOrBuildIncoming(
      int senderId, Map<String, dynamic> header) async {
    if (_sessions.containsKey(senderId)) return _sessions[senderId]!;

    final persisted = await _loadSession(senderId);
    if (persisted != null) {
      _sessions[senderId] = persisted;
      return persisted;
    }

    if (header['type'] != 'prekey') {
      throw StateError('[E2EE] pas de session pour $senderId et header non-prekey');
    }
    final state = await _buildIncoming(senderId, header);
    _sessions[senderId] = state;
    await _saveSession(senderId, state);
    return state;
  }

  // ── Persistance SQLite des sessions ───────────────────────────────────────

  Future<void> _saveSession(int peerId, _DrState s) async {
    if (_store == null) return;
    try {
      final rkBytes  = Uint8List.fromList(await s.rk.extractBytes());
      final cksBytes = s.cks != null
          ? Uint8List.fromList(await s.cks!.extractBytes()) : null;
      final ckrBytes = s.ckr != null
          ? Uint8List.fromList(await s.ckr!.extractBytes()) : null;
      final dhSPriv  = Uint8List.fromList(await s.dhS.extractPrivateKeyBytes());
      final dhRPub   = s.dhR != null
          ? Uint8List.fromList(s.dhR!.bytes) : null;

      final skippedJson = jsonEncode(
          s.skipped.map((k, v) => MapEntry(k, base64Encode(v))));
      final x3dhJson = s.x3dhHeader != null
          ? jsonEncode(s.x3dhHeader) : null;

      await _store.storeSession(E2eeSessionsCompanion(
        ownerUserId:   Value(_myId),
        peerId:        Value(peerId),
        rkBytes:       Value(rkBytes),
        cksBytes:      Value(cksBytes),
        ckrBytes:      Value(ckrBytes),
        dhSPriv:       Value(dhSPriv),
        dhRPub:        Value(dhRPub),
        ns:            Value(s.ns),
        nr:            Value(s.nr),
        pn:            Value(s.pn),
        skippedJson:   Value(skippedJson),
        x3dhHeaderJson: Value(x3dhJson),
      ));
    } catch (e) {
      debugPrint('[E2EE] _saveSession échoué (peer=$peerId): $e');
    }
  }

  Future<_DrState?> _loadSession(int peerId) async {
    if (_store == null) return null;
    try {
      final row = await _store.loadSession(_myId, peerId);
      if (row == null) return null;

      final rk  = SecretKey(row.rkBytes);
      final cks = row.cksBytes != null ? SecretKey(row.cksBytes!) : null;
      final ckr = row.ckrBytes != null ? SecretKey(row.ckrBytes!) : null;
      final dhS = await X25519().newKeyPairFromSeed(row.dhSPriv);
      final dhR = row.dhRPub != null
          ? SimplePublicKey(row.dhRPub!, type: KeyPairType.x25519) : null;

      final skipped = <String, List<int>>{};
      try {
        final j = jsonDecode(row.skippedJson) as Map<String, dynamic>;
        j.forEach((k, v) => skipped[k] = base64Decode(v as String));
      } catch (_) {}

      Map<String, dynamic>? x3dhHeader;
      if (row.x3dhHeaderJson != null) {
        try {
          x3dhHeader = jsonDecode(row.x3dhHeaderJson!) as Map<String, dynamic>;
        } catch (_) {}
      }

      return _DrState(
        rk: rk, cks: cks, ckr: ckr,
        dhS: dhS, dhR: dhR,
        x3dhHeader: x3dhHeader,
      )
        ..ns      = row.ns
        ..nr      = row.nr
        ..pn      = row.pn
        ..skipped = skipped;
    } catch (e) {
      debugPrint('[E2EE] _loadSession échoué (peer=$peerId): $e');
      return null;
    }
  }

  // ── Double Ratchet helpers ────────────────────────────────────────────────

  Future<void> _dhRatchet(_DrState s, SimplePublicKey newDhR) async {
    s.pn  = s.ns;
    s.ns  = 0;
    s.nr  = 0;
    s.dhR = newDhR;
    s.x3dhHeader = null;

    final (rk1, ckr) = await _kdfRk(s.rk, await _dh(s.dhS, newDhR));
    s.ckr = ckr;

    s.dhS = await X25519().newKeyPair();
    final (rk2, cks) = await _kdfRk(rk1, await _dh(s.dhS, newDhR));
    s.rk  = rk2;
    s.cks = cks;
  }

  Future<void> _skipMsgKeys(_DrState s, int until) async {
    if (s.nr >= until || s.ckr == null) return;
    if (until - s.nr > _maxSkip) throw StateError('[E2EE] trop de msg sautés');
    final dhrKey = s.dhR != null ? base64Encode(s.dhR!.bytes) : 'none';
    while (s.nr < until) {
      final (newCkr, mk) = await _kdfCk(s.ckr!);
      s.ckr = newCkr;
      s.skipped['$dhrKey:${s.nr}'] = await mk.extractBytes();
      s.nr++;
    }
  }

  // ── KDF ───────────────────────────────────────────────────────────────────

  Future<SecretKey> _dh(SimpleKeyPair kp, SimplePublicKey pub) =>
      X25519().sharedSecretKey(keyPair: kp, remotePublicKey: pub);

  Future<(SecretKey, SecretKey)> _kdfRk(SecretKey rk, SecretKey dhOut) async {
    final out = await Hkdf(hmac: Hmac.sha256(), outputLength: 64).deriveKey(
      secretKey: dhOut,
      nonce: await rk.extractBytes(),
      info: utf8.encode('talky-dr-rk-v1'),
    );
    final b = await out.extractBytes();
    return (SecretKey(b.sublist(0, 32)), SecretKey(b.sublist(32)));
  }

  Future<(SecretKey, SecretKey)> _kdfCk(SecretKey ck) async {
    final hmac    = Hmac.sha256();
    final ckBytes = await ck.extractBytes();
    final mk    = await hmac.calculateMac([0x01], secretKey: SecretKey(ckBytes));
    final newCk = await hmac.calculateMac([0x02], secretKey: SecretKey(ckBytes));
    return (SecretKey(newCk.bytes), SecretKey(mk.bytes));
  }

  Future<SecretKey> _x3dhKdf(List<SecretKey> dhs) async {
    final f   = Uint8List(32)..fillRange(0, 32, 0xFF);
    final ikm = <int>[...f];
    for (final s in dhs) {
      ikm.addAll(await s.extractBytes());
    }
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(ikm),
      nonce: Uint8List(32),
      info: utf8.encode('talky-x3dh-v1'),
    );
  }

  // ── AES-256-GCM ───────────────────────────────────────────────────────────

  Future<(List<int>, List<int>)> _aesgcmEncrypt(
      SecretKey mk, List<int> plain) async {
    final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
    final box   = await AesGcm.with256bits()
        .encrypt(plain, secretKey: mk, nonce: nonce);
    return ([...box.cipherText, ...box.mac.bytes], nonce);
  }

  Future<String> _aesgcmDecrypt(
      SecretKey mk, List<int> payload, List<int> nonce) async {
    const macLen = 16;
    final box = SecretBox(
      payload.sublist(0, payload.length - macLen),
      nonce: nonce,
      mac: Mac(payload.sublist(payload.length - macLen)),
    );
    return utf8.decode(
        await AesGcm.with256bits().decrypt(box, secretKey: mk));
  }

  // ── Utils ──────────────────────────────────────────────────────────────────

  bool _pubEq(SimplePublicKey a, SimplePublicKey b) {
    if (a.bytes.length != b.bytes.length) return false;
    for (int i = 0; i < a.bytes.length; i++) {
      if (a.bytes[i] != b.bytes[i]) return false;
    }
    return true;
  }

  /// Vide le cache mémoire (logout). Les sessions restent dans SQLite.
  void clear() {
    _myId = 0;
    _identity = null;
    _sessions.clear();
    _pendingOtpks.clear();
  }
}
