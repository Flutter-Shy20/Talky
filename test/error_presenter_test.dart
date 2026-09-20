import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/errors/app_error.dart';
import 'package:talky_flutter/core/errors/error_kind.dart';
import 'package:talky_flutter/core/errors/error_presenter.dart';
import 'package:talky_flutter/l10n/app_localizations.dart';
import 'package:talky_flutter/talky_api_client.dart';

/// Le presenter est le seul point autorisé à transformer une erreur en texte.
/// Ces tests fixent son contrat : rien de technique ne doit franchir la sortie.
void main() {
  late AppLocalizations fr;
  late AppLocalizations en;
  late AppLocalizations zh;

  setUpAll(() {
    fr = lookupAppLocalizations(const Locale('fr'));
    en = lookupAppLocalizations(const Locale('en'));
    zh = lookupAppLocalizations(const Locale('zh'));
  });

  String presenter(AppLocalizations l10n, Object? e, ErrorDomain d) =>
      presenterErreur(l10n, e,
          domaine: d, journaliser: false, avecDiagnostic: false);

  group('la sortie ne contient jamais de détail technique', () {
    // Le cœur de l'audit : ces chaînes s'affichaient réellement à l'écran.
    final erreurs = <String, Object>{
      'coupure DNS': const SocketException(
          "Failed host lookup: 'www.alanya237.com'"),
      'délai': TimeoutException('Future not completed'),
      'TLS': const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
      'plateforme': PlatformException(code: 'NotReadableError', message:
          'Could not start video source'),
      'prose serveur': TalkyException('Utilisateur non trouvé ou banni', 403),
      'table MySQL': TalkyException('ER_NO_SUCH_TABLE: alanya.appareils', 500),
      'état Dart': StateError('Bad state: SESSION_BUSY'),
    };

    const interdits = [
      'Exception',
      'Error',
      'SocketException',
      'Failed host lookup',
      'CERTIFICATE',
      'ER_NO_SUCH_TABLE',
      'alanya.appareils',
      'Could not start video source',
      'Utilisateur non trouvé',
      'Bad state',
      'null',
    ];

    for (final entree in erreurs.entries) {
      test('${entree.key} — aucun fragment technique en sortie', () {
        for (final domaine in ErrorDomain.values) {
          final texte = presenter(fr, entree.value, domaine);
          for (final interdit in interdits) {
            expect(
              texte.toLowerCase(),
              isNot(contains(interdit.toLowerCase())),
              reason: '« $interdit » a fui dans « $texte » '
                  '(domaine ${domaine.name}, cas ${entree.key})',
            );
          }
          expect(texte.trim(), isNotEmpty);
        }
      });
    }
  });

  group('ordre de résolution', () {
    test('1 — le code du serveur prime sur tout le reste', () {
      final e = TalkyException('peu importe', 409, code: 'TRUST_LIST_EMPTY');
      expect(presenter(fr, e, ErrorDomain.trajet), fr.errCodeTrustListEmpty);
      // Même dans un domaine sans rapport : le code est plus précis.
      expect(presenter(fr, e, ErrorDomain.chat), fr.errCodeTrustListEmpty);
    });

    test('1b — identifiants invalides ≠ session expirée', () {
      final e = TalkyException('Identifiants invalides', 401,
          code: 'INVALID_CREDENTIALS');
      expect(presenter(fr, e, ErrorDomain.auth), fr.errCodeInvalidCredentials);
      expect(presenter(fr, e, ErrorDomain.auth), isNot(fr.errSessionExpiree));
    });

    test('2 — domaine × nature quand le code manque', () {
      final horsLigne = TalkyException('', 0,
          cause: const SocketException('offline'));
      expect(presenter(fr, horsLigne, ErrorDomain.appel), fr.errAppelHorsLigne);
      expect(presenter(fr, horsLigne, ErrorDomain.chat), fr.errChatHorsLigne);
    });

    test('3 — la nature seule quand le croisement n\'existe pas', () {
      final horsLigne = TalkyException('', 0,
          cause: const SocketException('offline'));
      expect(presenter(fr, horsLigne, ErrorDomain.profil), fr.networkError);
    });

    test('4 — le repli du domaine quand la nature est inconnue', () {
      final opaque = Exception('quelque chose d\'illisible');
      expect(presenter(fr, opaque, ErrorDomain.reunion), fr.errDomaineReunion);
      expect(presenter(fr, opaque, ErrorDomain.generique), fr.errGenerique);
    });

    test('un code inconnu du catalogue ne bloque pas la résolution', () {
      // Le backend peut ajouter des codes à son rythme : l'application retombe
      // sur le statut sans rien afficher de brut.
      final e = TalkyException('', 404, code: 'UN_CODE_JAMAIS_VU');
      expect(presenter(fr, e, ErrorDomain.chat), fr.errIntrouvable);
    });
  });

  group('couverture du catalogue', () {
    test('chaque nature produit un texte dans les trois langues', () {
      for (final kind in ErrorKind.values) {
        for (final l10n in [fr, en, zh]) {
          final texte = presenter(
              l10n, AppError(kind: kind), ErrorDomain.generique);
          expect(texte.trim(), isNotEmpty,
              reason: 'nature ${kind.name} sans texte');
        }
      }
    });

    test('chaque domaine produit un texte dans les trois langues', () {
      for (final domaine in ErrorDomain.values) {
        for (final l10n in [fr, en, zh]) {
          final texte = presenter(l10n, Exception('x'), domaine);
          expect(texte.trim(), isNotEmpty,
              reason: 'domaine ${domaine.name} sans texte');
        }
      }
    });

    test('le chinois ne retombe pas sur du français', () {
      // Régression visée : la prose du serveur, toujours française, était
      // affichée telle quelle à un utilisateur en chinois.
      final e = TalkyException('Utilisateur non trouvé ou banni', 403);
      final texte = presenter(zh, e, ErrorDomain.auth);
      expect(texte, isNot(contains('Utilisateur')));
      expect(texte, matches(RegExp(r'[一-鿿]')));
    });
  });

  group('une erreur nulle reste présentable', () {
    test('null donne le repli du domaine, pas « null »', () {
      final texte = presenter(fr, null, ErrorDomain.media);
      expect(texte, fr.errDomaineMedia);
    });
  });
}
