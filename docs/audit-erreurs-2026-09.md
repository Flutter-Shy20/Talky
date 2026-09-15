# Audit — erreurs brutes affichées à l'utilisateur

Date : 2026-09-09 · Périmètre : `lib/` (90 écrans) + `Alanya-Backend/src`

Objectif : aucune erreur brute ne doit atteindre l'écran. L'utilisateur ne doit
lire que des textes prévus, traduits en fr/en/zh, du login jusqu'au fond de l'app.

---

## 1. Les quatre causes racines

Le problème n'est pas dispersé en 60 bugs indépendants : il tient à quatre
défauts de plomberie qui produisent mécaniquement tous les symptômes.

### R1 — `TalkyException` jette le champ `code` du backend

`lib/talky_api_client.dart:178-195` ne retient que `body['error']` et le
`statusCode`. Le `code` machine envoyé par le serveur est perdu à la frontière.

Conséquence directe : l'app ne peut plus distinguer les cas autrement qu'en
lisant la prose. D'où le string-matching :

- `lib/screens/trips/trip_compose_screen.dart:109` — `e.message.contains('TRUST_LIST_EMPTY')`,
  juste sous un commentaire qui affirme « On distingue les cas par le code
  renvoyé par le serveur, jamais par le texte du message ». Le code n'était pas
  disponible ; le commentaire décrit l'intention, pas le code écrit.
- `lib/screens/profile/contact_list_detail_screen.dart:86` — `e.message.toLowerCase().contains('limit')`.
- `lib/core/services/meeting/meeting_join_refusal.dart:37-45` — quatre `texte.contains('SESSION_BUSY')`,
  `'MEETING_ENDED'`, `'MEETING_EXPIRED'`, `'NOT_A_PARTICIPANT'` sur le
  `toString()` d'un `StateError`. Le commentaire l'assume : « les codes voyagent
  dans le message d'un `StateError` […] et rien ne garantit qu'ils garderont ce
  véhicule ».

Ces tests cassent silencieusement dès que le backend reformule une phrase.

### R2 — La prose du serveur est affichée telle quelle

Le backend renvoie **604 réponses `error:`**, dont **135 seulement portent un
`code`**. Le reste est de la prose libre, écrite en français, mêlée d'anglais
(`'Meeting not found'`) et de codes bruts (`'MEDIA_EXPIRED'`, `'ER_NO_SUCH_TABLE'`,
`'INTERNAL'`).

Aucune localisation côté serveur : `grep -i accept-language` ne remonte que
`welcomeController` et `conversationController`, pour le contenu d'accueil —
jamais pour les erreurs. **Un utilisateur en zh ou en en lit donc du français**,
et parfois un identifiant de table MySQL.

18 sites affichent `e.message` directement (liste en §2).

### R3 — 25 gabarits de traduction sont conçus pour recevoir une exception

Le fond du problème : l'app a localisé *l'emballage* et laissé l'exception
remplir le trou. `"errorColon": "Erreur: {error}"` est correctement traduit en
trois langues, et sert à afficher `SocketException: Failed host lookup`.

| Gabarit | Texte fr | Sites |
|---|---|---|
| `errorWithDetails` | Échec : {error} | 8 |
| `errorColon` | Erreur: {error} | 8 |
| `anErrorOccurred` | Une erreur est survenue: {error} | 4 |
| `exportFailed` | Export impossible : {error} | 3 |
| `cannotOpenFileApp` | Aucune app pour ouvrir ce fichier ({message}) | 3 |
| `actionFailedWithError` | Action impossible : {error} | 3 |
| `sendFailedWithError` | Échec de l'envoi : {error} | 2 |
| `uploadFailedWithError` | Échec de l'upload : {error} | 1 |
| `unableToPostStatusWithError` | Impossible de publier le statut : {error} | 1 |
| `roleChangeError` | Erreur changement de rôle: {error} | 1 |
| `recordFailedWithError` | Échec de l'enregistrement : {error} | 1 |
| `networkErrorWithDetails` | Erreur réseau: {error} | 1 |
| `loadUsersError` | Erreur chargement utilisateurs: {error} | 1 |
| `loadErrorWithDetails` | Erreur chargement : {error} | 1 |
| `deleteErrorWithDetails` | Erreur suppression: {error} | 1 |
| `deleteAccountFailed` | Suppression impossible : {error} | 1 |
| `copyImpossible` | Copie impossible : {error} | 1 |
| `cannotUnblockWithError` | Impossible de débloquer : {error} | 1 |
| `cannotOpenFileAppAlt` | Aucune application pour ouvrir ce fichier ({message}) | 1 |
| `cannotLoadMeeting` | Impossible de charger la réunion : {error} | 1 |
| `cannotJoinMeeting` | Impossible de rejoindre : {error} | 1 |
| `cannotCreateMeeting` | Impossible de créer la réunion : {error} | 1 |
| `biometricLockFailed` | Biométrie : {error} | 1 |
| `banUnbanError` | Erreur ban/unban: {error} | 1 |
| `meetingConnectFailed` | Échec de la connexion à la réunion : {error} | 0 (mort) |

**48 sites d'appel.** Trois gabarits supplémentaires exposent un détail
technique qui n'est pas une exception mais n'a rien à faire à l'écran :

- `copyFailedPath` = « Copie échouée : {path} » — chemin interne du sandbox
- `sourceFileNotFound` = « Fichier source introuvable : {path} » — idem
- `invalidResponseWithCode` = « Réponse invalide ({code}) » — code HTTP nu

(`qrMyCodeShareId`, `userHashId`, `userIdLabel` exposent aussi un `{id}`, mais
c'est intentionnel et légitime — hors périmètre.)

### R4 — La couche réseau injecte elle-même l'exception dans le texte

`lib/talky_api_client.dart:170-175` :

```dart
} catch (e) {
  throw TalkyException(
    LocaleController.instance.l10n.networkErrorWithDetails('$e'),
    0,
  );
}
```

Toute panne réseau non typée devient un message *déjà formaté pour l'écran*,
contenant le `toString()` de l'exception Dart. Ce message traverse ensuite
toutes les couches et ressort dans une SnackBar. C'est la source la plus
diffuse : elle contamine tous les domaines à la fois, y compris ceux dont
l'écran est par ailleurs propre.

---

## 2. Recensement par domaine

**62 sites d’affichage direct dans 31 fichiers.** Classés par gravité.

### Gravité 1 — exception nue, sans aucun emballage

| Fichier | Ligne | Code |
|---|---|---|
| `lib/screens/calls/ongoing_call_screen.dart` | 203 | `SnackBar(content: Text('$e'))` |

Un seul site, mais le pire : ajout d'un participant à un appel en cours, l'écran
affiche `NoSuchMethodError: ...` en toutes lettres.

### Gravité 2 — connexion et création de compte

C'est le premier écran de l'application, et il est touché.

| Fichier | Ligne | Ce qui s'affiche |
|---|---|---|
| `lib/providers/auth_provider.dart` | 262 | `_error = e.message` — prose serveur (login) |
| `lib/providers/auth_provider.dart` | 265 | `anErrorOccurred('$e')` — login |
| `lib/providers/auth_provider.dart` | 297 | `_error = e.message` — login QR |
| `lib/providers/auth_provider.dart` | 300 | `anErrorOccurred('$e')` — login QR |
| `lib/providers/auth_provider.dart` | 359 | `_error = e.message` — inscription |
| `lib/providers/auth_provider.dart` | 362 | `anErrorOccurred('$e')` — inscription |
| `lib/screens/authentification/forgot_password_screen.dart` | 66, 68 | `e.message`, `errorColon('$e')` |
| `lib/screens/onboarding/steps/profile_step.dart` | 195 | `_saveError = '$e'` |

`login_screen.dart:135` et `signup_screen.dart:171` affichent `auth.error!` sans
filtre. Hors ligne, l'utilisateur lit :
« Une erreur est survenue: SocketException: Failed host lookup: 'www.alanya237.com' ».

### Gravité 2 — appels

| Fichier | Ligne | Ce qui s'affiche |
|---|---|---|
| `lib/core/services/call/call_one_to_one.dart` | 162 | `errorColon(e.toString())` — fallback de `initiateCall` |
| `lib/core/services/call/call_one_to_one.dart` | 388 | `errorColon(e.toString())` — fallback de `answerCall` |
| `lib/screens/calls/keypad_screen.dart` | 352 | `errorColon('$e')` |
| `lib/screens/calls/call_detail_screen.dart` | 134 | `actionFailedWithError('$e')` |
| `lib/screens/calls/ongoing_call_screen.dart` | 203 | `Text('$e')` (cf. gravité 1) |

Les deux fallbacks alimentent `CallService.errorMessage`, relayé dans une
SnackBar par `keypad_screen.dart:299`, `call_detail_screen.dart:86`,
`chat_actions.dart:2005` et `incoming_call_screen.dart:168`.

Défaut supplémentaire : le tri d'erreurs de `call_one_to_one.dart:147-163` et
`:377-389` procède par `e.toString().toLowerCase().contains('permission')`.
Fragile par nature — le texte de `getUserMedia` n'est stable ni entre versions
de `flutter_webrtc`, ni entre Android et iOS.

### Gravité 2 — réunions

| Fichier | Ligne | Ce qui s'affiche |
|---|---|---|
| `lib/screens/meetings/meeting_lobby_screen.dart` | 139 | `cannotJoinMeeting('$erreur')` |
| `lib/screens/meetings/meeting_detail_screen.dart` | 168 | `cannotLoadMeeting('$e')` |
| `lib/screens/meetings/meets_screen.dart` | 222 | `cannotCreateMeeting('$erreur')` |

`meeting_lobby_screen.dart:122-128` documente le choix explicitement :

> « Les erreurs non classées gardent leur message d'origine — une exception HTTP
> porte déjà une phrase du serveur, plus précise que ce qu'on écrirait ici. »

C'est exactement la décision à renverser. Un échec `getUserMedia` tombe dans la
branche `autre` et s'affiche « Impossible de rejoindre : NotReadableError: Could
not start video source ».

**Bug additionnel — mapping mort.** `lib/core/services/meeting_service.dart:1024-1044`
construit soigneusement un `errorMsg` localisé sur cinq branches
(`permission`, `getusermedia`, `notfounderror`, `notreadableerror`, défaut),
puis le `debugPrint` et fait `rethrow`. **Le message mappé n'est jamais montré** :
c'est l'exception brute qui remonte au lobby. Le travail est fait mais jeté.

### Gravité 2 — scan de code QR

| Fichier | Ligne | Ce qui s'affiche |
|---|---|---|
| `lib/screens/profile/qr_scanner_screen.dart` | 137 | `_ => e.message` |
| `lib/core/services/qr_contact_flow.dart` | 222 | `e.statusCode == 404 ? ... : e.message` |
| `lib/screens/profile/qr_login_confirm_screen.dart` | 127 | `_afficher(e.message, ...)` |
| `lib/screens/profile/connected_devices_screen.dart` | 143 | `e is TalkyException ? e.message : ...` |
| `lib/screens/profile/qr_code_screen.dart` | 169-171 | `_errorMessage` → `error.message` |

400 et 404 sont bien traités ; tout le reste (403, 409, 410, 500) retombe sur la
prose serveur. Un QR périmé affiche le texte brut du backend.

À noter en positif : `_CameraError` (`qr_scanner_screen.dart:581-608`) traite
proprement le refus de permission caméra. **C'est le modèle à généraliser.**

### Gravité 2 — chat et statuts

| Fichier | Ligne | Ce qui s'affiche |
|---|---|---|
| `lib/screens/chats/chats_screen.dart` | 1065, 1096, 1110, 1121, 1133, 1145, 1157 | `errorWithDetails('$e')` × 7 |
| `lib/screens/chats/chat_detail_screen.dart` | 739 | `cannotUnblockWithError('$e')` |
| `lib/screens/chats/contact_detail_screen.dart` | 336, 368 | `actionFailedWithError('$e')` |
| `lib/screens/status/status_viewer_screen.dart` | 495, 587 | `sendFailedWithError('$e')` |
| `lib/screens/status/status_create_screen.dart` | 456 | `e is TalkyException ? e.message : e.toString()` |

Le corps du chat est par ailleurs sain : `chat_actions.dart` utilise partout des
clés dédiées (`unableToShareTheMessage`, `actionFailedPleaseTryAgain`). **C'est
le second modèle de référence.** Les fuites sont concentrées dans les actions de
liste (archiver, épingler, supprimer, sourdine) de `chats_screen.dart`.

### Gravité 3 — profil, médias, administration

| Fichier | Lignes |
|---|---|
| `lib/screens/profile/change_email_screen.dart` | 77, 83, 106, 112 |
| `lib/screens/profile/change_password_screen.dart` | 66, 72 |
| `lib/screens/profile/export_data_screen.dart` | 58, 83, 127 |
| `lib/screens/profile/edit_profile_screen.dart` | 244, 288, 345 |
| `lib/screens/profile/delete_account_screen.dart` | 60 |
| `lib/screens/profile/account_security_screen.dart` | 200 |
| `lib/screens/profile/recovery_code_screen.dart` | 46 |
| `lib/screens/profile/my_media_screen.dart` | 80 |
| `lib/screens/profile/ringtone_settings_screen.dart` | 121 |
| `lib/screens/profile/contact_list_detail_screen.dart` | 86 |
| `lib/core/utils/media_staging.dart` | 20, 36, 40 (chemins + `FileSystemException.message`) |
| `lib/providers/admin_provider.dart` | 90, 122, 132, 144 |
| `lib/screens/admin/admin_reserved_phones_screen.dart` | 83, 85, 89, 91, 130, 142 |
| `lib/screens/admin/admin_create_user_screen.dart` | 104, 258 |
| `lib/screens/admin/admin_user_detail_screen.dart` | 93 (`snapshot.error`) |

L'admin reste utile en interne, mais `admin_user_detail_screen.dart:93` affiche
un `snapshot.error` de `FutureBuilder` — trace Dart complète à l'écran.

### Ce qui est déjà propre — à ne pas toucher

- `lib/screens/trips/*` — `trip_compose_screen.dart:107-114` fait un `switch` sur
  `statusCode` avec repli localisé. Seul le `contains('TRUST_LIST_EMPTY')` est à
  reprendre une fois `code` disponible.
- `lib/core/utils/media_save_feedback.dart` — entièrement en clés dédiées.
- `lib/screens/chats/chat/chat_actions.dart` — clés dédiées.
- `_CameraError` du scanner QR.
- `main.dart:96-105` — `FlutterError.onError` et `platformDispatcher.onError`
  routent déjà vers Crashlytics sans rien afficher. La capture est bonne ; c'est
  la *restitution* qui manque.

### Faux positifs écartés

- `ForwardResult.errors` (`share_to_conversation_screen.dart:130`,
  `chat_repository.dart:705,863`) collecte des `e.toString()` — mais le champ
  n'est jamais lu à l'écran. Collecte morte, à supprimer, sans risque utilisateur.
- `l10n/app_localizations_*.dart` : fichiers générés, ne pas éditer à la main.

---

## 3. Ce que l'audit ne couvre pas

- **Le web** (`lib/` est partagé, mais `PLAN-WEB.md` a son propre périmètre).
- **Les notifications push** : les textes viennent du backend et ne passent pas
  par les gabarits `{error}`. À auditer séparément.
- **Les 469 `debugPrint`/`AppLog`** contenant `$e` : c'est leur rôle, ils ne
  s'affichent pas. Aucune action.
