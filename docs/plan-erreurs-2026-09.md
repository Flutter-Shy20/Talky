# Plan — capture et affichage des erreurs

Suite de [`audit-erreurs-2026-09.md`](audit-erreurs-2026-09.md).

> **État au 10/09/2026 — lots A livrés** sur la branche `erreurs-audit`
> (15 commits, depuis `crashlytics`). Les lots B (backend) restent à faire.
>
> Trois écarts avec le plan initial, décidés en cours de route :
> - **A10 (admin) a été conservé**, en version mécanique. Il devait être
>   repoussé, mais `errorColon` et `loadErrorWithDetails` sont partagés entre
>   l'admin et sept écrans utilisateur : les y laisser aurait interdit A11,
>   donc la garantie structurelle entière. Aucun message admin n'a été rédigé
>   par code — ce travail-là reste bien repoussé.
> - **Un commit non prévu**, `fix(erreurs): trier sur le code, plus sur la
>   prose du serveur` : le test-garde a révélé deux branches qui décidaient de
>   l'affichage en cherchant un mot dans le message serveur.
> - **28 clés supprimées** au lieu de 25 : les trois clés annexes prévues
>   (`copyFailedPath`, `sourceFileNotFound`, `invalidResponseWithCode`) sont
>   bien parties, et quatre sites affichant le message anglais du plugin
>   OpenFilex ont été repris au passage.
>
> Vérification : `flutter analyze` sans erreur (48 avertissements, tous
> préexistants) ; suite complète à 16 échecs, **identiques à ceux de la base**
> — aucune régression, et un échec préexistant réparé
> (`media_staging_test`, qui butait sur le `StateError` de `LocaleController`).

Règle visée : **aucune exception, aucun texte serveur, aucun chemin de fichier
n'atteint l'écran.** L'utilisateur ne lit que des phrases écrites à l'avance,
traduites en fr/en/zh. Le détail technique part vers Crashlytics, pas vers lui.

---

## 1. Le principe : rendre la faute inécrivable

L'audit montre que le problème n'est pas l'inattention : `errorColon('$e')` a été
écrit 8 fois parce que **l10n offrait un trou à remplir**. Tant que
`"Erreur: {error}"` existe, quelqu'un y mettra une exception.

Le plan repose donc moins sur la correction des 62 sites que sur la suppression
de ce qui les rend possibles :

1. **On supprime les 25 gabarits à trou.** Après le lot A11, l'API de traduction
   n'offre plus aucun emplacement où glisser une exception. La faute devient une
   erreur de compilation, pas un oubli de relecture.
2. **Un entonnoir unique.** `ErrorPresenter` est le seul point du code autorisé à
   transformer une erreur en texte. Il ne reçoit jamais de `String` à concaténer.
3. **Un test-garde**, dans la lignée de `l10n_parity_test.dart`, qui scanne les
   sources et refuse la régression.

### L'entonnoir

```dart
// lib/core/errors/error_presenter.dart
String presenterErreur(
  AppLocalizations l10n,
  Object erreur, {
  required ErrorDomain domaine,
});
```

Résolution, dans l'ordre, en s'arrêtant au premier succès :

| # | Critère | Exemple |
|---|---|---|
| 1 | `code` backend connu | `TRUST_LIST_EMPTY` → « Votre cercle de confiance est vide. » |
| 2 | `ErrorKind` + domaine | `offline` + `call` → « Appel impossible sans connexion. » |
| 3 | Repli du domaine | `meeting` → « La réunion n'a pas pu s'ouvrir. Réessayez. » |
| 4 | Repli global | « Une erreur est survenue. Réessayez. » |

`ErrorKind` est déduit du `statusCode` et du type d'exception Dart
(`SocketException`, `TimeoutException`, `PlatformException`, erreurs
`getUserMedia`), **jamais du texte**. C'est ce qui remplace les
`e.toString().contains('permission')` de `call_one_to_one.dart`.

`erreur` n'est jamais interpolée dans le résultat. Elle part à `AppLog.e` avec
son `code`, donc Crashlytics conserve exactement ce que l'écran cesse de montrer :
la capacité de diagnostic ne baisse pas, elle change de destinataire.

En `kDebugMode` uniquement, le presenter suffixe `[code · statut]` — le confort
de développement est préservé sans toucher les builds de production.

### Les deux repos sont indépendants

Le client lit `body['code']` **défensivement** : absent, il retombe sur le
`ErrorKind` déduit du statut HTTP. Les lots A n'attendent donc pas les lots B, et
chaque code ajouté côté serveur affine l'affichage sans redéploiement de l'app.
C'est ce qui permet de livrer l'app d'abord, là où le bénéfice utilisateur est.

---

## 2. Ordre de livraison

Les lots A1–A3 ne changent rien à l'écran : ils posent la plomberie. Le premier
gain visible est **A4 (connexion)**, à faire en premier car c'est le seul écran
que 100 % des utilisateurs traversent, et il fuit aujourd'hui hors ligne.

Ensuite par volume de fuite : appels (A5), réunions (A6), chat (A7), QR (A8).
A11 (suppression des gabarits) ne peut venir qu'après A4–A10, sinon la
compilation casse. A12 verrouille.

---

## 3. Commits — dépôt `Alanya`, branche `erreurs-audit` (depuis `main`)

**A0** · `docs(erreurs): recensement des erreurs brutes affichées à l'utilisateur`
- `docs/audit-erreurs-2026-09.md` (nouveau)
- `docs/plan-erreurs-2026-09.md` (nouveau)

**A1** · `feat(erreurs): AppError et le classement des pannes par nature`
- `lib/core/errors/app_error.dart` (nouveau — `AppError`, `ErrorDomain`, `ErrorKind`)
- `lib/core/errors/error_kind.dart` (nouveau — déduction depuis statut HTTP et type d'exception)
- `test/error_kind_test.dart` (nouveau)

**A2** · `feat(erreurs): TalkyException transporte le code renvoyé par le serveur`
- `lib/talky_api_client.dart` — `_parseResponse` lit `body['code']` ; `_handleRequest` cesse d'injecter `'$e'` dans le message (cause R4)
- `lib/core/utils/app_exceptions.dart` — `AppException.code` aligné
- `test/talky_exception_code_test.dart` (nouveau)

**A3** · `feat(erreurs): l'entonnoir unique de présentation des erreurs`
- `lib/core/errors/error_presenter.dart` (nouveau)
- `lib/l10n/app_fr.arb`, `app_en.arb`, `app_zh.arb` — catalogue des clés par domaine, **sans placeholder**
- `lib/l10n/app_localizations*.dart` (régénérés)
- `test/error_presenter_test.dart` (nouveau)

**A4** · `fix(erreurs): connexion, inscription et onboarding ne montrent plus l'exception`
- `lib/providers/auth_provider.dart` (l. 262, 265, 297, 300, 359, 362)
- `lib/screens/authentification/login_screen.dart` (l. 135)
- `lib/screens/authentification/signup_screen.dart` (l. 65, 171)
- `lib/screens/authentification/forgot_password_screen.dart` (l. 66, 68)
- `lib/screens/onboarding/steps/profile_step.dart` (l. 195)

(`qr_login_screen.dart:215` est déjà sain — il bascule sur `_reseauDegrade` sans
rien afficher de brut. À ne pas toucher.)

**A5** · `fix(erreurs): appels — le tri cesse de lire le texte de l'exception`
- `lib/core/services/call/call_one_to_one.dart` (l. 147-163, 377-389 — `contains` → `ErrorKind`)
- `lib/screens/calls/ongoing_call_screen.dart` (l. 203 — le `Text('$e')` nu)
- `lib/screens/calls/keypad_screen.dart` (l. 299, 352)
- `lib/screens/calls/call_detail_screen.dart` (l. 86, 134)
- `lib/screens/calls/incoming_call_screen.dart` (l. 168)
- `lib/screens/chats/chat/chat_actions.dart` (l. 2005)
- `test/call_error_kind_test.dart` (nouveau)

**A6** · `fix(erreurs): réunions — le message mappé cesse d'être jeté`
- `lib/core/services/meeting_service.dart` (l. 1024-1044 — le `rethrow` qui perd `errorMsg` ; lever une `AppError` portée)
- `lib/screens/meetings/meeting_lobby_screen.dart` (l. 122-141 — la branche `autre`)
- `lib/screens/meetings/meeting_detail_screen.dart` (l. 168)
- `lib/screens/meetings/meets_screen.dart` (l. 222)
- `lib/core/services/meeting/meeting_join_refusal.dart` (l. 37-45) — les quatre
  `texte.contains(...)` sur un `StateError` remplacés par le `code` porté ;
  nouveaux motifs (média refusé, périphérique occupé)
- `test/meeting_join_refusal_test.dart` (étendu)

**A7** · `fix(erreurs): chat, statuts et contacts`
- `lib/screens/chats/chats_screen.dart` (l. 1065, 1096, 1110, 1121, 1133, 1145, 1157)
- `lib/screens/chats/chat_detail_screen.dart` (l. 739)
- `lib/screens/chats/contact_detail_screen.dart` (l. 336, 368)
- `lib/screens/status/status_viewer_screen.dart` (l. 495, 587)
- `lib/screens/status/status_create_screen.dart` (l. 456)

**A8** · `fix(erreurs): scan de code et connexion par QR`
- `lib/screens/profile/qr_scanner_screen.dart` (l. 132-138 — la branche `_ => e.message`)
- `lib/core/services/qr_contact_flow.dart` (l. 218-224)
- `lib/screens/profile/qr_login_confirm_screen.dart` (l. 127)
- `lib/screens/profile/connected_devices_screen.dart` (l. 143)
- `lib/screens/profile/qr_code_screen.dart` (l. 169-171 — `_errorMessage` renvoie `error.message`)

**A9** · `fix(erreurs): profil, médias et export`
- `lib/screens/profile/change_email_screen.dart` (l. 77, 83, 106, 112)
- `lib/screens/profile/change_password_screen.dart` (l. 66, 72)
- `lib/screens/profile/export_data_screen.dart` (l. 58, 83, 127)
- `lib/screens/profile/edit_profile_screen.dart` (l. 244, 288, 345)
- `lib/screens/profile/delete_account_screen.dart` (l. 60)
- `lib/screens/profile/account_security_screen.dart` (l. 200)
- `lib/screens/profile/recovery_code_screen.dart` (l. 46)
- `lib/screens/profile/my_media_screen.dart` (l. 80)
- `lib/screens/profile/ringtone_settings_screen.dart` (l. 121)
- `lib/screens/profile/contact_list_detail_screen.dart` (l. 86 — `contains('limit')` → code)
- `lib/core/utils/media_staging.dart` (l. 20, 36, 40 — chemins et `FileSystemException.message`)
- `test/media_staging_test.dart` (étendu)

**A10** · `fix(erreurs): administration`
- `lib/providers/admin_provider.dart` (l. 90, 122, 132, 144)
- `lib/screens/admin/admin_reserved_phones_screen.dart` (l. 83, 85, 89, 91, 130, 142)
- `lib/screens/admin/admin_create_user_screen.dart` (l. 104, 258)
- `lib/screens/admin/admin_user_detail_screen.dart` (l. 93 — `snapshot.error`)

**A11** · `refactor(erreurs): suppression des 25 gabarits à trou`
- `lib/l10n/app_fr.arb`, `app_en.arb`, `app_zh.arb` — retrait des 25 clés `{error}` + `copyFailedPath`, `sourceFileNotFound`, `invalidResponseWithCode`
- `lib/l10n/app_localizations.dart`, `app_localizations_fr.dart`, `app_localizations_en.dart`, `app_localizations_zh.dart` (régénérés)

**A12** · `test(erreurs): garde contre le retour des erreurs brutes`
- `test/error_presentation_guard_test.dart` (nouveau) — échoue si un `.arb` réintroduit un placeholder `{error}`/`{path}`, ou si `lib/screens`/`lib/widgets`/`lib/providers` contient `Text('$e')`, `e.toString()` ou `e.message` dans un contexte d'affichage

**A13** · `chore(erreurs): retrait de la collecte morte de ForwardResult.errors`
- `lib/core/utils/forward_message.dart`
- `lib/screens/chats/share_to_conversation_screen.dart` (l. 130)
- `lib/core/services/chat/chat_repository.dart` (l. 705, 863)
- `test/forward_message_test.dart` (ajusté)

---

## 4. Commits — dépôt `Alanya-Backend`, branche `erreurs-codes` (depuis `main`)

604 réponses `error:`, dont 135 seulement portent un `code`. Les lots suivent le
volume par contrôleur, en commençant par ce que l'app affiche le plus.

**B1** · `feat(erreurs): helper de réponse d'erreur à code stable`
- `src/utils/apiError.js` (nouveau — `fail(res, status, code, message)`)
- `src/utils/apiError.test.js` (nouveau)
- `docs/error-codes.md` (nouveau — catalogue partagé avec l'app)
- `package.json` (script `test:erreurs`)

**B2** · `feat(erreurs): codes stables sur l'authentification` (66 + 43)
- `src/controllers/authCustomController.js`
- `src/middleware/authCustom.js`, `src/middleware/adminAuth.js`
- `docs/error-codes.md`

**B3** · `feat(erreurs): codes stables sur conversations, messages et listes` (96)
- `src/controllers/conversationController.js`, `messageController.js`, `contactListController.js`
- `docs/error-codes.md`

**B4** · `feat(erreurs): codes stables sur appels, réunions et QR` (41)
- `src/controllers/callController.js`, `meetingController.js`, `qrController.js`, `qrAuthController.js`, `qrLandingController.js`
- `src/middleware/meetingAuth.js` (dont `'Meeting not found'`, resté en anglais)
- `docs/error-codes.md`

**B5** · `feat(erreurs): codes stables sur trajets, statuts, médias et compte` (72)
- `src/controllers/tripController.js`, `statutController.js`, `uploadController.js`, `profileMediaController.js`, `mediaAvailabilityController.js`, `accountLifecycleController.js`, `backupController.js`, `userController.js`
- `src/middleware/mediaExpiry.js` (`'MEDIA_EXPIRED'` placé en `error`, à déplacer en `code`)
- `docs/error-codes.md`

**B6** · `feat(erreurs): codes stables sur l'administration et le reste` (~50)
- `src/controllers/adminController.js`, `src/controllers/admin/*`
- `appSettingsController.js`, `dndScheduleController.js`, `notificationPrefsController.js`, `preferredContactController.js`, `privacyPrefsController.js`, `pushDevicesController.js`, `reportController.js`, `welcomeController.js`
- `src/services/*`, `src/routes/*`
- `docs/error-codes.md`

**B7** · `fix(erreurs): aucune erreur MySQL ne sort du serveur`
- `src/utils/apiError.js` — filtre les `ER_*` et les messages de driver vers `INTERNAL`
- `src/controllers/*` — sites où `err.message` partait tel quel (dont `'ER_NO_SUCH_TABLE'`)

**B8** · `test(erreurs): garde — toute réponse 4xx/5xx porte un code`
- `src/utils/errorCodeCoverage.test.js` (nouveau) — scanne `src/` et échoue sur toute réponse d'erreur sans `code`

---

## 5. Points à trancher

1. **Faut-il traduire côté serveur ?** Non, à mon sens : le serveur envoie un
   `code`, l'app le traduit. C'est ce que suppose ce plan. L'alternative
   (`Accept-Language` côté backend) dupliquerait le catalogue en trois langues
   dans deux dépôts et laisserait les erreurs socket sans solution.
2. **Le champ `error` en prose survit-il ?** Oui, conservé pour les journaux et
   la compatibilité des clients non mis à jour — mais l'app cesse de le lire.
   À retirer dans une version ultérieure, pas ici.
3. **Portée admin.** Les écrans d'administration sont internes. A10 les traite
   par cohérence, mais ils peuvent être repoussés sans risque utilisateur si le
   calendrier presse.

## 6. Vérification

- `flutter test` — 95 tests existants + 6 nouveaux fichiers
- `flutter analyze` après A11 : la suppression des gabarits doit ne laisser
  **aucune** référence orpheline ; c'est la preuve mécanique que les 48 sites
  d'appel ont tous été repris
- Recette manuelle, mode avion activé : login, envoi d'un message, appel,
  réunion, scan QR — chaque écran doit afficher une phrase prévue, jamais
  « SocketException »
