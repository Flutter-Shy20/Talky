# Appels — chantier « application fermée ou en arrière-plan » (08–09/2026)

Suite de [`audit-appels-2026-07.md`](audit-appels-2026-07.md). Ce document consigne le
chantier mené du 23/08 au 02/09/2026, de l'audit initial jusqu'à sa clôture, côté
application. Le versant serveur est dans
[`Alanya-Backend/docs/audit-appels-backend-2026-09.md`](../../Alanya-Backend/docs/audit-appels-backend-2026-09.md).

Branche : `appels-audit`. 72 commits.

## Ce qui a déclenché le chantier

L'audit du 23–25/08 a produit 47 entrées classées par ce qu'elles cassent. Elles sont
soldées. Se sont ensuite ajoutées deux campagnes de vérification et, surtout, les
**observations terrain de l'utilisateur** — qui ont donné les vraies causes à chaque fois,
là où les lectures de code produisaient des hypothèses plausibles et fausses.

Trois symptômes rapportés ont structuré la suite :

1. « Un délai de 25 secondes avant d'entendre les voix. »
2. « Quand un appel dure trop, quand on raccroche ça ne raccroche pas chez l'autre mais ça
   met Reconnecting… jusqu'à se couper. »
3. « Le bouton décrocher ouvre un écran qui sonne encore au lieu de décrocher, ou bien avec
   deux sonneries. »

---

## Les causes de fond

### Le socket qui paraît vivant et ne l'est plus

Socket.IO ne constate une chute de TCP qu'au bout de son ping — 25 secondes d'intervalle,
20 de patience. Pendant ces quarante-cinq secondes, `isSocketReady` répond `true` et tout ce
qu'on émet part dans le vide, sans un mot. Le code connaissait le phénomène pour la
messagerie — `main.dart` porte le commentaire « ne pas faire confiance à `isSocketReady`
(zombie TCP) » — mais pas pour les appels.

Trois conséquences, corrigées séparément :

- **Le raccrochage se perdait** (`f63b2b1`, serveur `f3b1355`). `end_call` partait sans
  accusé de réception, et un socket non authentifié était traité côté serveur par un
  `return` muet. Toutes les sorties du handler accusent désormais, et sans réponse en trois
  secondes le client remet le raccrochage en file **et** fait reconstruire le socket.
- **La réponse WebRTC aussi** (`d1955dc`, serveur `79f7920`). C'est pourtant le seul message
  que l'appelant attend. Perdue, elle ne repartait jamais : l'appelé affichait « en cours »
  avec son chronomètre, l'appelant restait sur « connexion ».
- **Rien ne remettait le socket en cause pendant une reconnexion** (`f63b2b1`). Les offres
  de reprise repartaient toutes les cinq secondes dans le même vide jusqu'au délai global.
  Un audit unique, huit secondes après l'entrée en reconnexion, le reconstruit s'il n'a plus
  rien livré — une seule fois par épisode, sans quoi aucune négociation n'aurait le temps
  d'aboutir.

Cause aggravante corrigée dans le même geste (`38f8143`) : `flushOutbox` démontait le socket
de signalisation toutes les soixante-quinze secondes dès qu'un message traînait sans accusé.
En pleine conversation, c'est l'appel qu'on coupait.

### La course du décrochage

Le bouton « Décrocher » de la notification pointe vers `TransparentActivity` du plugin, dont
`onCreate` fait, dans cet ordre :

```kotlin
sendBroadcast(broadcastIntent)   // asynchrone
startActivity(activityIntent)    // lance MainActivity tout de suite
```

Ces deux lignes partent en course. Le receiver, lui, n'écrit `isAccepted=true` qu'à son
avant-dernière instruction, et ses deux tentatives d'atteindre Flutter ne peuvent pas
aboutir à froid : l'une exige un moteur vivant, l'autre poste avec 750 ms de retard vers des
canaux déjà existants.

Application tuée, le démarrage de Flutter prend une à deux secondes et le receiver gagne
presque toujours. **Application en arrière-plan, le moteur est déjà vivant : Flutter gagne**,
lit un état encore non accepté, et présente un entrant. L'écran qui sonnait était celui du
plugin (`CallkitIncomingActivity`), qui vit dans sa propre tâche et ne se ferme que sur
diffusion.

`AppUtils.getAppIntent` posait pourtant l'action et les données de l'appel sur l'intent de
lancement de MainActivity — porté par le **même** `startActivity`, donc sans course possible.
Personne ne le lisait, ni le plugin ni nous.

`CallAcceptFromIntent` le lit maintenant (`91f3e30`) et écrit `isAccepted=true`. Rien
d'autre : le nettoyage complet existe déjà et n'a qu'une autorité, l'écouteur `ACTIVE_CALLS`
de `TalkyApplication`. Trois conditions gardent l'écriture, et elles sont écrites en premier
parce que c'est là qu'est le risque — action exacte, entrée déjà connue, consommation de
l'intent.

Le cas « moteur vivant mais endormi » est traité à part : `adoptNativeAcceptIfAny` est
interrogé avant toute reprise au premier plan, et adopte le décrochage plutôt que de le
contredire.

### Le natif sonnait sans consulter aucun état

`CallIncomingHelper.showIncoming` n'avait pour toute garde qu'un `lastShownCallId` en
mémoire de processus. Il ne lisait ni le registre des appels terminés, ni les appels actifs,
ni l'état des notifications (`651388d`). Trois symptômes en découlaient :

| | |
|---|---|
| Sonnerie fantôme | Un push `call` livré après son `call_ended` faisait sonner un appel déjà annulé. Le registre était écrit par Dart, jamais lu par le natif |
| Sonnerie par-dessus une conversation | Aucune consultation des appels acceptés en cours |
| Sonnerie aveugle | Notifications refusées : le plugin se tait et n'affiche rien, mais `CustomRingtonePlayer` démarrait quand même — en boucle, sans notification, sans écran, sans minuteur local |

### L'autorité de présentation existait, écrite et testée, jamais appelée

`decideIncomingPresentation` prenait exactement les bonnes décisions et n'était appelée que
par son propre test. En production, quatre sites recopiaient à la main
`if (_isAppForeground) flutter else native`, puis un second aiguillage décidait l'affichage
CallKit et la sonnerie. Deux aiguillages pour une seule question, qui divergeaient : ni le
groupe ni la conférence n'avaient de branche « premier plan », donc ils ne sonnaient pas
(`c4ff80c`).

Racine du problème : `_isAppForeground` rendait `true` quand l'état de cycle de vie était
encore inconnu — le cas exact d'un réveil par push derrière l'écran verrouillé.

### Le garde de session média, et sa correction à moitié faite

`CallSessionGuard.acquire` incrémentait son compteur puis sortait sans rien configurer quand
la session était déjà tenue, y compris par un **autre** appel. Le `release()` d'en face ne
redescendait alors jamais à zéro (`38f8143`).

La correction a créé son propre défaut : `release` gardait son décrément aveugle. Une
session dont l'acquisition avait été **refusée** faisait donc tomber le compteur à zéro en se
retirant, et démontait celle du voisin (`5868fcc`). Rejoindre une réunion pendant un appel,
ou l'inverse, coupait le service au premier plan de la session survivante.

### Le chemin de groupe

Le moins couvert, et le plus abîmé.

- **Décrocher depuis la notification n'aboutissait pas** (`ef6eb31`). `joinGroupCall` n'avait
  qu'un appelant dans toute l'application, le bouton de l'écran entrant.
- **Un refus de groupe empruntait le chemin 1-à-1** (`9fd6274`, serveur `6952ef3`) et
  réécrivait le dernier appel à deux en « refusé » chez les deux correspondants.
- **La fin d'un appel de groupe n'atteignait pas les invités hors ligne** (serveur `feb74e2`).

### Expiration ≠ refus

Un appel simplement non répondu s'inscrivait « Rejeté » dans le journal des deux
utilisateurs (`3a3bdc3`). Le natif n'avait structurellement aucun moyen de distinguer les
deux : l'écouteur `ACTIVE_CALLS` voit une entrée disparaître, sans savoir pourquoi.

Le discriminant s'est trouvé dans le plugin : la branche `DECLINE` de son receiver appelle
`notifyEventCallbacks`, la branche `TIMEOUT` **n'appelle rien**. Un rappel enregistré depuis
`TalkyApplication` — sans moteur Flutter — marque donc les vrais refus, et tout ce qui n'est
pas marqué est une expiration. Exact, pas inféré.

---

## Le reste, par thème

**Démarrage à froid** (`5f0fad4`) — l'action CallKit était dépilée après
`_syncSessionBindings`, qui attend un rafraîchissement HTTP des conversations et un vidage
complet de l'outbox, dont les téléversements ont des délais de garde de 30 à 600 secondes.

**Montée du plugin en 3.1.5** (`b475ac3`) — trois versions de retard. `CallEvent` devient une
hiérarchie scellée ; `activeCalls()` rend des objets typés là où trois lectures faisaient
`raw as Map?`, ce qui aurait levé à chaque appel ; deux événements ne portent plus que
l'identifiant, dont `timeout`, alors que le refus qu'il déclenche a besoin du `callerId` ; et
les libellés des boutons ont déménagé, des deux côtés de la frontière.

**Service au premier plan en `phoneCall`** (`409ef41`) — `microphone` et `camera` sont soumis
aux restrictions « while-in-use » : `startForeground` lève depuis Android 14 quand
l'application est en arrière-plan, c'est-à-dire au décrochage depuis une notification.

**Établissement borné** (`d1955dc`) — aucune horloge ne couvrait l'état `connecting` ; une
caméra refusée faisait refuser tout l'appel vidéo au lieu de dégrader en audio ; le répondeur
n'avait pas de tampon de candidats ICE, là où l'appelant en a un.

**Restauration après mort de processus** (`9952ab3`) — elle ne fonctionnait que pour
l'appelant, seul à persister un instantané. L'appelé confirmait pourtant la reprise au
serveur, ce qui annulait la grâce de déconnexion, puis jetait l'offre de rejointe.

**Quatre autres du même commit** — `onTaskRemoved` absent (notification « Appel en cours »
indéboulonnable après un balayage), la rotation du jeton FCM qui n'atteignait plus le
backend, le débris CallKit d'une réunion tuée, et la sonnerie par liste jamais décodable
application fermée (`e30bb61` — sentinelle `shared_preferences`).

---

## Méthode

Chaque décision a été extraite en fonction pure, testée, **puis neutralisée pour vérifier
que le test tombe**. Un test qui ne sait pas échouer ne prouve rien : deux tests écrits
pendant ce chantier ne savaient pas, et l'un couvrait un défaut réel.

Deux campagnes de vérification contradictoire ont été menées, chacune avec des agents
chargés de **réfuter** les constats plutôt que de les confirmer. Elles ont rendu :

- sur le correctif du décrochage, cinq verdicts « casse » sur une première version — dont
  deux recommandations qui se sont révélées **fausses** et auraient introduit des
  régressions ;
- sur le chemin fermé/arrière-plan, 48 constats dont sept passés à la contradiction, tous
  confirmés mais avec des rectifications de périmètre significatives.

Leçon à retenir : ces agents produisent des analyses bien argumentées et parfois fausses.
Elles se relisent, elles ne se croient pas.

## Vérification

- `flutter analyze lib/` — 48 avertissements, aucune erreur.
- `flutter test` — 758 réussis, 17 échecs préexistants dans trois fichiers sans rapport
  (`forward_message`, `chat_dao`, `alanya_phone_formatter`).
- **Les 321 tests du domaine appel passent tous**, vérifié en les lançant isolément.
- Suites backend : voir le document jumeau.

## Ce qui reste ouvert

**Hors chemin d'appel**, issu du triage du second anneau : `registerToken` n'est jamais
appelé donc `platform` reste à `unknown` ; la conversation active est ineffaçable côté
serveur ; les téléversements court-circuitent `_handleRequest` et ne rafraîchissent donc pas
le jeton sur 401 ; le rattrapage de piste micro morte repose sur `onEnded`, jamais appelé par
flutter_webrtc en natif.

**Écarts d'architecture assumés** — ce ne sont pas des défauts, mais ils bornent ce qu'on
peut promettre :

- Aucune connexion Telecom n'est enregistrée sur le chemin **entrant** : `CallIncomingHelper`
  court-circuite le receiver du plugin. Décrocher depuis une oreillette ou une montre n'a
  jamais fonctionné, un appel cellulaire ne met pas le nôtre en attente, et l'exemption
  d'accès micro en arrière-plan repose sur une prémisse que ce chemin ne remplit pas.
- Les appels de groupe plafonnent à 4 en vidéo et 6 en audio — topologie maillée.
- iOS ne fonctionne pas : les identifiants ne sont pas des UUID, donc le plugin n'enregistre
  aucun appel auprès de CallKit. Depuis la 3.1.5 il ne plante plus, il ignore.
- Rien n'est fait contre les restrictions constructeurs (Xiaomi, Transsion, Oppo).
- Pas d'appel en attente.

## Réserve de méthode

Tout ce qui précède est établi par test et relecture. **Les campagnes de tests sur appareil
se sont limitées à quelques téléphones.** À chaque tour de ce chantier, les vraies causes
sont venues des logs de terrain, jamais des lectures — le délai de vingt-cinq secondes, la
reconnexion qui n'aboutissait pas, l'écran qui sonnait encore. Il faut s'attendre à ce que la
prochaine campagne en révèle d'autres.
