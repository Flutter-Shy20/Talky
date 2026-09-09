import 'dart:async';
import 'dart:io';

import 'package:talky_flutter/core/errors/app_error.dart';
import 'package:talky_flutter/core/errors/error_kind.dart';
import 'package:talky_flutter/talky_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Le champ `code` du backend et la cause d'origine doivent survivre au passage
/// de la frontière HTTP.
///
/// Les perdre est la cause racine de l'audit des erreurs : sans `code`,
/// l'application ne peut plus distinguer les cas qu'en lisant la prose du
/// serveur ; sans `cause`, un `statusCode` de 0 confond une coupure réseau, un
/// délai dépassé et un refus TLS.
void main() {
  group('TalkyException', () {
    test('transporte le code du serveur', () {
      final e = TalkyException('peu importe', 409, code: 'TRUST_LIST_EMPTY');
      expect(e.code, 'TRUST_LIST_EMPTY');
      expect(AppError.from(e).code, 'TRUST_LIST_EMPTY');
    });

    test('code absent reste null sans faire échouer la normalisation', () {
      // Les routes non encore migrées côté backend n'envoient pas de code :
      // l'application doit continuer à fonctionner, en retombant sur le statut.
      final e = TalkyException('Utilisateur non trouvé', 404);
      final err = AppError.from(e);
      expect(err.code, isNull);
      expect(err.kind, ErrorKind.introuvable);
    });

    test('n\'expose pas le code dans toString quand il est absent', () {
      expect(TalkyException('x', 500).toString(), isNot(contains('Code')));
      expect(
        TalkyException('x', 500, code: 'INTERNAL').toString(),
        contains('INTERNAL'),
      );
    });
  });

  group('AppError.from — la cause prime sur le statut', () {
    test('une coupure réseau se distingue d\'un délai dépassé', () {
      // Les deux arrivent avec statusCode 0 : seul le type de la cause les
      // sépare, et on ne dit pas la même chose à l'utilisateur.
      final coupure = TalkyException('', 0,
          cause: const SocketException('Failed host lookup'));
      final delai = TalkyException('', 0, cause: TimeoutException('trop long'));

      expect(AppError.from(coupure).kind, ErrorKind.horsLigne);
      expect(AppError.from(delai).kind, ErrorKind.delaiDepasse);
    });

    test('un refus TLS ne passe pas pour une simple coupure', () {
      final tls = TalkyException('', 0, cause: const HandshakeException('bad cert'));
      expect(AppError.from(tls).kind, ErrorKind.reseauSuspect);
    });

    test('sans cause, le statut 0 vaut hors ligne', () {
      expect(AppError.from(TalkyException('', 0)).kind, ErrorKind.horsLigne);
    });

    test('une AppError déjà construite passe telle quelle', () {
      const source = AppError(kind: ErrorKind.permissionRefusee);
      expect(identical(AppError.from(source), source), isTrue);
    });
  });

  group('diagnostic', () {
    test('rassemble ce que l\'écran cesse de montrer', () {
      const err = AppError(
        kind: ErrorKind.conflit,
        code: 'SESSION_BUSY',
        statusCode: 409,
      );
      expect(err.diagnostic, 'conflit · SESSION_BUSY · HTTP 409');
    });
  });
}
