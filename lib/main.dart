import 'dart:async';
// import 'dart:io'; // requis pour HttpOverrides — réactiver avec le bloc certificate pinning

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:provider/provider.dart';
import 'l10n/app_localizations.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/connectivity_provider.dart';
import 'providers/status_provider.dart';
import 'providers/admin_provider.dart';
import 'core/db/app_database.dart';
import 'dart:convert';
import 'core/services/backup/restore_state.dart';
import 'screens/profile/restore_screen.dart';
import 'core/services/backup/backup_target.dart';
import 'core/services/backup/backup_runner.dart';
import 'core/services/backup/server_backup_key_provider.dart';
import 'core/services/backup/restore_service.dart';
import 'core/db/chat_dao.dart';
import 'core/services/translation/message_translation_service.dart';
import 'core/services/translation/translation_settings.dart';
// import 'core/network/cert_pinning.dart'; // réactiver avec le bloc certificate pinning
import 'core/navigation/app_navigator.dart';
import 'core/utils/app_log.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'core/theme/locale_controller.dart';
import 'core/services/chat/message_sound_service.dart';
import 'core/services/incoming_share_service.dart';
import 'core/services/media_download_preferences.dart';
import 'core/services/media_expiry_policy.dart';
import 'core/services/playback_speed_preferences.dart';
import 'core/services/ringtone_preferences.dart';
import 'core/services/list_ringtone_preferences.dart';
import 'core/services/call_service.dart';
import 'core/services/callkit_service.dart';
import 'core/services/call/ended_call_registry.dart';
import 'core/services/local_cache_repository.dart';
import 'core/services/trip_repository.dart';
import 'core/services/trip_socket_service.dart';
import 'core/services/trip_bootstrap.dart';
import 'core/services/local_hidden_store.dart';
import 'core/services/meeting_service.dart';
import 'core/services/presence_service.dart';
import 'core/services/qr_contact_flow.dart';
import 'core/services/qr_deep_link_service.dart';
import 'models/qr_models.dart';
import 'core/services/realtime_sync_service.dart';
import 'core/services/voice_message_coordinator.dart';
import 'core/services/voice_playback_service.dart';
import 'core/services/push_service.dart';
import 'core/services/session_end_reason.dart';
import 'core/services/notifications/notification_prefs_cache.dart';
import 'core/services/notifications/badge_sync_service.dart';
import 'core/services/notifications/pending_delivery_ack_store.dart';
import 'core/services/notifications/pending_notification_action_store.dart';
import 'core/services/privacy_prefs_service.dart';
import 'core/services/app_settings_sync_service.dart';
import 'core/services/biometric_lock_service.dart';
import 'core/services/storage_info_service.dart';
import 'firebase_options.dart';
import 'screens/onboarding/account_setup_flow.dart';
import 'screens/authentification/login_screen.dart';
import 'core/services/onboarding_service.dart';
import 'talky_api_client.dart';
import 'talky_models.dart';
import 'widgets/session/biometric_lock_overlay.dart';
import 'widgets/session/active_session_banner.dart';

/// Clé globale exposée à PushService pour naviguer depuis les notifications.
@Deprecated('Use appNavigatorKey from core/navigation/app_navigator.dart')
final GlobalKey<NavigatorState> navigatorKey = appNavigatorKey;

void main() async {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  // Garde le splash natif jusqu'à la restauration locale (pas de spinner Flutter).
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  debugPrint('[Main] ======== Application démarrée ========');

  // Photo Picker Android (grille + cases à cocher pour pickMultiImage / pickMultiVideo).
  // Sans ça, le plugin retombe sur l'ancien sélecteur fichiers (souvent identique
  // au picker une seule vidéo, multi via appui long — peu visible).
  final imagePickerImpl = ImagePickerPlatform.instance;
  if (imagePickerImpl is ImagePickerAndroid) {
    imagePickerImpl.useAndroidPhotoPicker = true;
    debugPrint('[Main] Android Photo Picker activé');
  }

  // Capture centralisée des erreurs non interceptées (UI + asynchrones).
  // Sans ça, une exception dans un build/callback partait dans le vide.
  FlutterError.onError = (details) {
    FlutterError.dumpErrorToConsole(details, forceReport: true);
    AppLog.e('FlutterError', details.exceptionAsString(),
        details.exception, details.stack);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    AppLog.e('PlatformDispatcher', 'Erreur asynchrone non interceptée',
        error, stack);
    return true;
  };

  // Certificate pinning : le backend utilisait un certificat auto-signé. On ne
  // faisait confiance qu'à ce certificat précis (embarqué dans les assets), ce qui
  // règle le HandshakeException sans ouvrir la porte au MITM. Couvre http,
  // uploads, socket.io et cached_network_image via HttpOverrides.global.
  //
  // DÉSACTIVÉ : réactiver avec PinnedCertHttpOverrides si besoin de pinning.
  // try {
  //   HttpOverrides.global = await PinnedCertHttpOverrides.load();
  //   debugPrint('[Main] Certificate pinning activé');
  // } catch (e) {
  //   debugPrint('[Main] ** Échec activation cert pinning: $e');
  // }

  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await CallKitService.instance.init();
    debugPrint('[Main] Firebase + CallKit initialisés');
  } catch (e) {
    debugPrint('[Main] ** Init Firebase échouée — push désactivé: $e');
  }

  // Charger avant runApp : le prefetch socket/sync lit ce flag de façon sync.
  await MediaDownloadPreferences.preload();
  // Rétention des médias apprise du serveur : permet de savoir qu'un média
  // est expiré sans lancer une requête vouée au 410.
  await MediaExpiryPolicy.preload();

  // Charger avant runApp : la première lecture applique la vitesse mémorisée
  // sans attendre, sinon le premier vocal repart à 1×.
  await PlaybackSpeedPreferences.preload();

  // Charger avant runApp : CallService/RingtoneService/CallKitService lisent
  // la sonnerie sélectionnée de façon synchrone dès le premier appel entrant.
  await RingtonePreferences.preload();
  await ListRingtonePreferences.preload();

  await AppSettingsSyncService.preloadLocal();

  final biometricLock = BiometricLockService();
  await biometricLock.ensureLoaded();

  await IncomingShareService.instance.init();

  // Précharge les sons de messagerie (envoi/réception). Non bloquant : assets
  // embarqués, aucune dépendance réseau.
  unawaited(MessageSoundService.instance.init());

  // Mise en place d'une base restaurée, s'il y en a une en attente.
  //
  // **Ici et nulle part ailleurs.** `AppDatabase` est un champ `late final` de
  // `TalkyApp` : une fois l'arbre construit, on ne remplace plus son instance,
  // et fermer la connexion ne suffirait pas — tout ce qui la détient
  // continuerait de pointer sur un objet fermé. À ce point du démarrage, rien
  // n'a encore ouvert le fichier : l'échange ne peut se heurter à personne.
  // Voir `RestoreService.stagePending`, qui a posé le fichier au lancement
  // précédent.
  try {
    const restoreState = RestoreStateStore();

    // Restauration interrompue en pleine écriture : la base contiendrait des
    // messages pour CERTAINES conversations seulement. Le rattrapage de
    // synchronisation les prendrait alors pour complètes et les sauterait
    // définitivement — les trous deviendraient permanents et silencieux.
    // Repartir d'une base vide coûte un rapatriement complet ; c'est
    // infiniment préférable à un historique troué sans que personne le sache.
    if (await restoreState.needsRecoveryAfterCrash()) {
      debugPrint('[Main] ** Restauration interrompue → purge et nouvelle offre');
      await RestoreService(
        closeDatabase: () async {},
        applyPrefs: (_) async {},
      ).wipe(await appDatabaseFile());
      await restoreState.setStage(RestoreStage.unknown);
    }

    if (await RestoreService.applyPendingSwap(await appDatabaseFile())) {
      debugPrint('[Main] Base restaurée mise en place');
      await restoreState.setStage(RestoreStage.done);
    } else if (await restoreState.hasPendingSwap()) {
      // Marqué « en attente » mais rien à mettre en place : le fichier déposé a
      // disparu, ou il était illisible et a été écarté. Laisser cet état
      // condamnerait la restauration en silence — elle ne serait plus jamais
      // reproposée, et l'inscrit n'aurait aucun moyen de le savoir. On repart
      // donc de zéro, quitte à reposer la question.
      debugPrint('[Main] ** Dépôt de restauration introuvable → remise à zéro');
      await restoreState.setStage(RestoreStage.unknown);
    }
  } catch (e) {
    // Un échec ici ne doit pas empêcher l'application de démarrer : la base
    // en place reste utilisable, et l'écran de restauration reproposera.
    debugPrint('[Main] ** Mise en place de la base restaurée échouée: $e');
  }

  runApp(TalkyApp(biometricLock: biometricLock));
}

class TalkyApp extends StatefulWidget {
  const TalkyApp({super.key, this.biometricLock});

  final BiometricLockService? biometricLock;

  @override
  State<TalkyApp> createState() => _TalkyAppState();
}

class _TalkyAppState extends State<TalkyApp> {
  late final TalkyApiClient _apiClient = TalkyApiClient();
  late final AppDatabase _database = AppDatabase();
  late final ChatProvider _chatProvider =
      ChatProvider(api: _apiClient, database: _database);
  late final LocalCacheRepository _localCache =
      LocalCacheRepository(db: _database, api: _apiClient);

  // Traduction des messages, entièrement sur l'appareil. Instanciée ici et non
  // dans un `create:` paresseux : `ChatRepository` appelle le service par son
  // instance statique dès la première synchronisation, avant que le moindre
  // écran de réglages ne l'ait lu.
  late final TranslationSettings _translationSettings = TranslationSettings()
    ..load();
  late final MessageTranslationService _translation =
      MessageTranslationService(
    dao: ChatDao(_database),
    settings: _translationSettings,
  );
  late final TripRepository _trips =
      TripRepository(db: _database, api: _apiClient);
  // Démarré ici et non dans un écran : les changements d'état d'un trajet
  // arrivent par le compte, donc sans souscription. Un trajet doit continuer
  // d'être suivi même quand aucun écran de trajet n'est ouvert.
  late final TripSocketService _tripSocket =
      TripSocketService(api: _apiClient, trips: _trips)..start();

  /// Reprise du suivi au démarrage. Vit hors des écrans : un trajet doit
  /// survivre à la navigation et au redémarrage de l'application, pas dépendre
  /// d'une page ouverte.
  late final TripBootstrap _tripBootstrap = TripBootstrap(
    api: _apiClient,
    trips: _trips,
    socket: _tripSocket,
  )..start();

  @override
  void initState() {
    super.initState();
    // Un changement d'état de trajet doit réécrire la carte déjà posée dans la
    // conversation. Seul le dépôt de chat sait retrouver la ligne et relancer le
    // recalcul de l'aperçu ; le service socket lui délègue.
    _tripSocket.bindCardWriter(_chatProvider.repository.updateTripCard);
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // ThemeController en tête : MaterialApp en dépend via Consumer.
        ChangeNotifierProvider(create: (_) => ThemeController()..load()),
        ChangeNotifierProvider(create: (_) => LocaleController()..load()),
        // Réglages de traduction : locaux et non synchronisés, car les modèles
        // de langue ML Kit sont téléchargés par appareil. Fournis par valeur,
        // donc réellement construits ici — le service doit exister avant la
        // première synchronisation, pas au premier écran qui le lira.
        ChangeNotifierProvider<TranslationSettings>.value(
            value: _translationSettings),
        Provider<MessageTranslationService>.value(value: _translation),
        ChangeNotifierProvider(
            create: (_) => MediaDownloadPreferences()..load()),
        Provider<TalkyApiClient>.value(value: _apiClient),
        Provider<AppDatabase>.value(value: _database),
        Provider<LocalCacheRepository>.value(value: _localCache),
        Provider<TripRepository>.value(value: _trips),
        Provider<TripSocketService>.value(value: _tripSocket),
        Provider<TripBootstrap>.value(value: _tripBootstrap),
        ChangeNotifierProvider(
            create: (_) => RingtonePreferences()..load()),
        ChangeNotifierProvider(
          // L'API sert à pousser les sonneries de liste sur le compte : le
          // choix suit l'utilisateur sur tous ses appareils.
          create: (ctx) =>
              ListRingtonePreferences(api: ctx.read<TalkyApiClient>())..load(),
        ),
        ChangeNotifierProvider(
            create: (_) => AuthProvider(apiClient: _apiClient)),
        ChangeNotifierProvider(
          create: (ctx) => PrivacyPrefsService(api: ctx.read<TalkyApiClient>())
            ..loadFromCache(),
        ),
        ChangeNotifierProvider(
          create: (_) => widget.biometricLock ?? (BiometricLockService()..load()),
        ),
        ChangeNotifierProvider(create: (_) => StorageInfoService()),
        ChangeNotifierProvider(
          create: (ctx) => AppSettingsSyncService(api: ctx.read<TalkyApiClient>()),
        ),
        // Déclaré avant CallService, qui s'y abonne dans son `create`.
        ChangeNotifierProvider(create: (_) => VoicePlaybackService()),
        ChangeNotifierProvider(create: (ctx) {
          final call = CallService(apiClient: _apiClient);
          final voice = ctx.read<VoicePlaybackService>();

          // Les événements de session à trois arrivent par socket sans passer
          // par un écran : le service doit connaître l'identité locale pour se
          // placer lui-même dans le roster.
          final auth = ctx.read<AuthProvider>();
          void pushIdentity() {
            final me = auth.currentUser;
            if (me == null) return;
            call.setLocalIdentity(
              id: me.alanyaID,
              name: me.nom.isNotEmpty ? me.nom : me.pseudo,
              photo: me.avatarUrl,
            );
          }
          pushIdentity();
          auth.addListener(pushIdentity);

          // Un appel — sonnerie comprise — ne doit pas se superposer à la
          // lecture en cours. `isCallActive` ignore le statut `incoming`,
          // d'où le test sur idle/ended plutôt que sur ce getter.
          var wasBusy = false;
          call.addListener(() {
            final busy = call.status != CallStatus.idle &&
                call.status != CallStatus.ended;
            if (busy && !wasBusy && voice.isPlaying) voice.pause();
            wasBusy = busy;
          });
          return call;
        }),
        ChangeNotifierProvider(
            create: (_) => MeetingService(apiClient: _apiClient)),
        ChangeNotifierProvider.value(value: _chatProvider),
        ChangeNotifierProvider(
            create: (_) =>
                StatusProvider(api: _apiClient, cache: _localCache)),
        ChangeNotifierProvider(create: (_) => AdminProvider(api: _apiClient)),
        ChangeNotifierProvider(
            create: (_) => ConnectivityProvider(api: _apiClient)),
        ChangeNotifierProvider(create: (_) => LocalHiddenStore()..load()),
        ChangeNotifierProvider(
          create: (ctx) => VoiceMessageCoordinator(
            repository: ctx.read<ChatProvider>().repository,
          ),
        ),
        Provider<RealtimeSyncService>(
          create: (ctx) => RealtimeSyncService(
            chat: ctx.read<ChatProvider>(),
            status: ctx.read<StatusProvider>(),
          ),
        ),
        // Présence : « en ligne » ⇔ app au premier plan, ou appel/réunion en
        // cours. Déclaré après CallService et MeetingService, dont il dépend.
        Provider<PresenceService>(
          create: (ctx) {
            final call = ctx.read<CallService>();
            final meeting = ctx.read<MeetingService>();
            final presence = PresenceService(
              sendPresence: _apiClient.sendPresence,
              registerResolver: _apiClient.setPresenceOnlineCallback,
              isSessionActive: () =>
                  (call.status != CallStatus.idle &&
                      call.status != CallStatus.ended) ||
                  meeting.currentMeeting != null,
            );
            presence.bindSessionSource(call);
            presence.bindSessionSource(meeting);
            return presence;
          },
          dispose: (_, presence) => presence.dispose(),
        ),
      ],
      child: Consumer3<ThemeController, LocaleController, AppSettingsSyncService>(
        builder: (_, tc, lc, __, ___) => MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [appRouteObserver],
          scaffoldMessengerKey: appMessengerKey,
          debugShowCheckedModeBanner: false,
          onGenerateTitle: (ctx) => AppLocalizations.of(ctx)?.appTitle ?? 'Alanya',
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: tc.mode,
          locale: lc.locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          localeResolutionCallback: (device, supported) {
            if (lc.preference != AppLocalePreference.system && lc.locale != null) {
              return lc.locale;
            }
            if (device != null) {
              for (final l in supported) {
                if (l.languageCode == device.languageCode) return l;
              }
            }
            return const Locale('fr');
          },
          builder: (context, child) {
            final media = MediaQuery.of(context);
            return ActiveSessionChrome(
              child: MediaQuery(
                data: media.copyWith(
                  textScaler: TextScaler.linear(
                    AppSettingsSyncService.fontScale,
                  ),
                  disableAnimations: AppSettingsSyncService.reduceMotion,
                ),
                child: child ?? const SizedBox.shrink(),
              ),
            );
          },
          home: const AuthWrapper(),
        ),
      ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  AuthProvider? _authProvider;
  int? _boundUserId;


  /// Sérialise logout → login : évite qu'un re-login rapide (même compte)
  /// soit ignoré pendant que le vidage local est encore en cours.
  Future<void> _sessionBindingsChain = Future.value();
  VoidCallback? _onBackOnline;
  ConnectivityProvider? _connectivityForListener;
  void Function(dynamic)? _onCallLogUpdated;
  Timer? _callSyncFallbackTimer;

  /// Révocation de CET appareil depuis un autre appareil du compte. L'abonnement
  /// vit ici et non dans un écran : l'événement peut tomber à tout moment, et un
  /// abonné visible seulement sur l'écran « Appareils connectés » le laisserait
  /// filer (flux broadcast, sans mémoire tampon) — l'app resterait alors sur
  /// l'écran d'accueil avec une session morte.
  StreamSubscription<void>? _deviceRevokedSub;

  /// Liens `…/q/u/<jeton>` ouverts depuis la page web d'un code QR partagé.
  /// L'abonnement vit ici pour capter aussi bien le lien qui a démarré l'app
  /// que ceux reçus pendant qu'elle tourne.
  StreamSubscription<({String kind, String token})>? _qrLinkSub;

  /// Quelqu'un vient d'utiliser mon code QR : invitation à l'ajouter en
  /// retour. L'abonnement vit ici et non sur l'écran « Mon code » — le code a
  /// pu être partagé par lien, son propriétaire peut être n'importe où dans
  /// l'app quand le scan survient.
  StreamSubscription<QrContactScan>? _qrScanSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    debugPrint('[AuthWrapper] initState - Lancement de init()');
    _authProvider = Provider.of<AuthProvider>(context, listen: false);
    _authProvider!.addListener(_onAuthChanged);
    _deviceRevokedSub = Provider.of<TalkyApiClient>(context, listen: false)
        .thisDeviceRevoked
        .listen((_) => unawaited(_authProvider?.handleRemoteRevocation() ?? Future.value()));
    _qrLinkSub = QrDeepLinkService.instance.identityTokens
        .listen((lien) => unawaited(_handleQrIdentityLink(lien)));
    _qrScanSub = Provider.of<TalkyApiClient>(context, listen: false)
        .qrContactScans
        .listen((scan) => unawaited(_onQrContactScanned(scan)));
    unawaited(QrDeepLinkService.instance.start());
    Future.microtask(_bootstrap);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authProvider?.removeListener(_onAuthChanged);
    _deviceRevokedSub?.cancel();
    _qrLinkSub?.cancel();
    _qrScanSub?.cancel();
    _clearCallLogBindings();
    if (_onBackOnline != null && _connectivityForListener != null) {
      _connectivityForListener!.removeBackOnlineListener(_onBackOnline!);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final auth = _authProvider;
    if (auth == null) return;
    unawaited(() async {
      await auth.refreshSessionOnResume();
      if (!mounted || !auth.isLoggedIn) return;
      await _ensureSocketReadyOnResume();
      // Sauvegarde automatique : la politique est temporelle, donc il suffit
      // de lui demander son avis au retour au premier plan. Elle ne fait rien
      // si ce n'est pas dû, si le réseau est mesuré, ou si l'inscrit a choisi
      // « Jamais ». Voir `BackupRunner` pour la raison de ce choix plutôt
      // qu'une tâche de fond.
      await _maybeRunBackup();
    }());
  }

  /// Demande au planificateur si une sauvegarde est due, et la lance le cas
  /// échéant. Silencieux de bout en bout : une sauvegarde automatique qui
  /// échoue ne doit jamais interrompre l'inscrit, l'écran de réglages en rend
  /// compte et la politique décide s'il faut en parler.
  /// Empile l'écran de restauration par-dessus tout ce qui est affiché.
  ///
  /// **Par la navigation, et non par le `build`.** La question se pose au
  /// milieu d'une séquence asynchrone, pas à la reconstruction d'un widget :
  /// la faire passer par un drapeau consulté dans `build` obligerait à
  /// synchroniser les deux, pour un écran qui n'apparaît qu'une fois dans la
  /// vie d'un appareil.
  ///
  /// `fullscreenDialog` et l'absence de bouton retour font le reste : l'inscrit
  /// tranche, il ne contourne pas.
  void _offerRestore(BackupAnnouncement announcement) {
    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      debugPrint('[Restore] ** aucun navigateur disponible → écran non empilé');
      return;
    }
    // Après la trame en cours : `LoginScreen` vient de faire un
    // `pushAndRemoveUntil`, et empiler pendant qu'une transition de route est
    // en vol peut se perdre sans le moindre message.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('[Restore] empilement de l\'écran de restauration');
      _pushRestore(navigator, announcement);
    });
  }

  void _pushRestore(NavigatorState navigator, BackupAnnouncement announcement) {
    navigator.push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (routeContext) => _restoreScreenFor(
        routeContext,
        announcement,
        onSettled: () {
          if (navigator.canPop()) navigator.pop();
          _onRestoreSettled();
        },
      ),
    ));
  }

  /// Écran bloquant de restauration.
  ///
  /// Il reçoit tout en paramètres — base, clés, destination — plutôt que d'aller
  /// les chercher lui-même : c'est ce qui rend ses scénarios d'échec jouables
  /// en test, et ce qui permettra de remplacer le stockage local par Drive sans
  /// le toucher.
  ///
  /// Le contexte vient de la route elle-même, jamais de l'`AuthWrapper`. Les
  /// fournisseurs sont déclarés au-dessus du `MaterialApp`, donc visibles
  /// depuis n'importe quelle route ; et cet écran cesse ainsi de dépendre de la
  /// durée de vie d'un état qui ne le concerne pas.
  Widget _restoreScreenFor(
    BuildContext context,
    BackupAnnouncement announcement, {
    required VoidCallback onSettled,
  }) {
    final chat = Provider.of<ChatProvider>(context, listen: false);
    final api = Provider.of<TalkyApiClient>(context, listen: false);
    return FutureBuilder<BackupTarget>(
      future: BackupRunner.readTarget(),
      builder: (context, snapshot) {
        final target = snapshot.data;
        if (target == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return RestoreScreen(
          db: chat.repository.dao.db,
          target: target,
          keys: ServerBackupKeyProvider((path) async {
            final kid = path.startsWith('/backup/key/')
                ? int.tryParse(path.substring('/backup/key/'.length))
                : null;
            return jsonEncode(await api.fetchBackupKey(kid: kid));
          }),
          announcement: announcement,
          onSkip: onSettled,
        );
      },
    );
  }

  /// Demande au serveur s'il connaît une sauvegarde pour ce compte.
  ///
  /// Retourne `true` si l'écran de restauration doit prendre la main — auquel
  /// cas l'appelant s'arrête là et ne lie rien.
  ///
  /// Silencieux en cas d'échec : un serveur injoignable ne doit pas empêcher
  /// d'entrer dans l'application. On repose la question au prochain démarrage.
  Future<bool> _shouldOfferRestore(TalkyApiClient api) async {
    try {
      if (!await const RestoreStateStore().shouldOffer()) {
        debugPrint('[Restore] déjà tranché sur cet appareil → pas de proposition');
        return false;
      }
      final json = await api.fetchBackupMeta();
      // Tracé explicitement : sans ça, « aucune proposition » est indiscernable
      // de « le serveur ne connaît pas de sauvegarde », et on ne peut que
      // deviner lequel des deux maillons casse.
      debugPrint('[Restore] réponse du serveur : $json');
      final announcement = BackupAnnouncement.fromJson(json);
      if (announcement == null) return false;

      // Pas de garde `mounted` : rien sur ce trajet ne dépend plus de l'état de
      // l'`AuthWrapper`. L'empilement passe par la clé de navigation globale,
      // et l'écran lit ses fournisseurs depuis le contexte de sa propre route.
      // Un abandon silencieux ici serait indiagnosticable.
      _offerRestore(announcement);
      return true;
    } catch (e) {
      debugPrint('[AuthWrapper] proposition de restauration ignorée: $e');
      return false;
    }
  }

  /// L'inscrit a refusé, ou la restauration est prête et il rouvrira
  /// l'application. On reprend la liaison normale des fournisseurs.
  void _onRestoreSettled() {
    // `_syncSessionBindings` s'était arrêté net pour laisser la base tranquille
    // pendant la restauration. Le relancer est ce qui lie enfin la messagerie,
    // le socket et la présence : sans cet appel, l'application resterait une
    // coquille. Il aboutit parce que cet état est toujours monté — ce qui n'est
    // vrai que depuis la suppression des `pushAndRemoveUntil((route) => false)`
    // du chemin de connexion.
    if (!mounted) return;

    _sessionBindingsChain =
        _sessionBindingsChain.then((_) => _syncSessionBindings());
  }

  Future<void> _maybeRunBackup() async {
    if (!mounted) return;
    try {
      final chat = Provider.of<ChatProvider>(context, listen: false);
      final api = Provider.of<TalkyApiClient>(context, listen: false);
      // Sert uniquement à pré-sélectionner le bon compte Google : connaître
      // l'adresse n'ouvre évidemment aucun droit sur le Drive.
      final email =
          Provider.of<AuthProvider>(context, listen: false).currentUser?.email;
      // Le service passe par son fournisseur : `ConnectivityService` n'est pas
      // dans l'arbre, et le chercher directement lèverait — silencieusement
      // avalé par le `catch` ci-dessous, la sauvegarde ne tournerait jamais.
      final connectivity =
          Provider.of<ConnectivityProvider>(context, listen: false).service;
      final myId = chat.repository.myId;
      if (myId == 0) return;

      await BackupRunner(
        db: chat.repository.dao.db,
        connectivity: connectivity,
        accountEmail: email,
        keys: ServerBackupKeyProvider((path) async {
          final kid = path.startsWith('/backup/key/')
              ? int.tryParse(path.substring('/backup/key/'.length))
              : null;
          return jsonEncode(await api.fetchBackupKey(kid: kid));
        }),
        onSucceeded: (meta) => api.publishBackupMeta(
          bytes: meta.bytes,
          kid: meta.kid,
          messageCount: meta.messageCount,
        ),
      ).maybeRun(alanyaID: myId);
    } catch (e) {
      debugPrint('[Main] sauvegarde automatique ignorée: $e');
    }
  }

  Future<void> _ensureSocketReadyOnResume() async {
    if (!mounted) return;
    final apiClient = Provider.of<TalkyApiClient>(context, listen: false);
    final chat = Provider.of<ChatProvider>(context, listen: false);

    // Pending outbox : ne pas faire confiance à isSocketReady (zombie TCP).
    final hasPending = await chat.repository.hasSyncPending();
    if (!mounted) return;
    if (hasPending) {
      debugPrint('[AuthWrapper] Resume pending outbox → forceReconnect + flush');
      final ready = await apiClient.forceReconnect();
      if (!mounted) return;
      await chat.repository.flushOutbox();
      debugPrint('[AuthWrapper] Resume reconnect ready=$ready');
      return;
    }

    if (apiClient.isSocketReady) return;
    final ready = await apiClient.ensureSocketReady();
    debugPrint('[AuthWrapper] Resume socket ready=$ready');
  }

  void _removeBackOnlineListener() {
    if (_onBackOnline != null && _connectivityForListener != null) {
      _connectivityForListener!.removeBackOnlineListener(_onBackOnline!);
      _onBackOnline = null;
      _connectivityForListener = null;
    }
  }

  void _removeCallLogListener() {
    if (_onCallLogUpdated == null) return;
    try {
      Provider.of<TalkyApiClient>(context, listen: false)
          .removeSocketListener(SocketEvents.callLogUpdated, _onCallLogUpdated!);
    } catch (e) {
      debugPrint('[AuthWrapper] removeCallLogListener échoué: $e');
    }
    _onCallLogUpdated = null;
  }

  void _cancelCallSyncFallback() {
    _callSyncFallbackTimer?.cancel();
    _callSyncFallbackTimer = null;
  }

  void _scheduleCallSyncFallback(LocalCacheRepository cache, int myId) {
    _cancelCallSyncFallback();
    _callSyncFallbackTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      unawaited(cache.syncCalls(myId: myId));
    });
  }

  void _bindCallLogListener(int myId) {
    _removeCallLogListener();
    final apiClient = Provider.of<TalkyApiClient>(context, listen: false);
    final cache = Provider.of<LocalCacheRepository>(context, listen: false);
    final callService = Provider.of<CallService>(context, listen: false);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);

    _onCallLogUpdated = (data) async {
      debugPrint('[AuthWrapper] call_log_updated → upsertCallFromPayload');
      await cache.upsertCallFromPayload(
        data,
        myId: myId,
        onMissingConversation: () => chatProvider.refreshConversations(force: true),
      );
      if (!mounted) return;
      _scheduleCallSyncFallback(cache, myId);
    };
    apiClient.onSocketEvent(SocketEvents.callLogUpdated, _onCallLogUpdated!);
    callService.onCallTerminatedHook = () async {
      if (!mounted) return;
      _scheduleCallSyncFallback(cache, myId);
    };
  }

  void _clearCallLogBindings() {
    _removeCallLogListener();
    _cancelCallSyncFallback();
    try {
      Provider.of<CallService>(context, listen: false).onCallTerminatedHook = null;
    } catch (e) {
      debugPrint('[AuthWrapper] clearCallLogBindings échoué: $e');
    }
  }

  /// Bootstrap initial : restaure le cache local, retire le splash, puis lie
  /// les providers. La validation réseau de session continue en arrière-plan.
  Future<void> _bootstrap() async {
    final apiClient = Provider.of<TalkyApiClient>(context, listen: false);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    try {
      try {
        await authProvider.init();
        debugPrint('[AuthWrapper] !! init() local complété');
      } finally {
        // Toujours retirer le splash : sinon écran figé si init échoue.
        FlutterNativeSplash.remove();
      }
      await _syncSessionBindings();

      // Actions CallKit dispatchées AVANT PushService.init : un accept depuis
      // la notification (app tuée) doit atteindre CallService dès que la
      // session locale est restaurée. PushService.init fait du réseau
      // (getToken FCM) et d'éventuels dialogues de permission — l'attendre
      // ici retardait l'écran d'appel de plusieurs secondes après le tap
      // « Accepter » (spinner → home → appel).
      void dispatch(IncomingCallAction action) {
        if (!mounted) return;
        final callService = Provider.of<CallService>(context, listen: false);
        unawaited(callService.handleCallKitAction(action));
      }

      CallKitService.instance.setIncomingCallPreviewListener(dispatch);
      CallKitService.instance.actions.listen(dispatch);

      final pending = CallKitService.instance.consumePendingAction();
      if (pending != null) {
        debugPrint('[AuthWrapper]  Pending CallKit action trouvée: ${pending.action}');
        debugPrint('[AuthWrapper] Dispatcher l\'action...');
        dispatch(pending);
        debugPrint('[AuthWrapper] !! Action dispatchée');
      } else {
        debugPrint('[AuthWrapper] ℹ Aucune action pending au démarrage');
        // Repli cold start : l'événement CallKit est souvent perdu avant que Flutter
        // soit prêt. activeCalls() conserve isAccepted côté natif.
        final active = await CallKitService.instance.getActiveCall();
        if (!mounted) return;
        if (active == null) {
          // Rien de plausible : retirer d'éventuels débris (entrées trop
          // vieilles) sans déclencher de reject natif (purge programmatique).
          unawaited(CallKitService.instance.purgeStaleActiveCalls());
        }
        if (active != null) {
          final callId = active['callId'] as String? ?? '';
          if (callId.startsWith('meeting_')) {
            debugPrint('[AuthWrapper] ℹ CallKit réunion ignoré au cold start: $callId');
          } else if (callId.isNotEmpty && await EndedCallRegistry.isEnded(callId)) {
            debugPrint('[AuthWrapper] 🛡 CallKit terminé ignoré au cold start: $callId');
            await CallKitService.instance.endAll(callId: callId);
          } else if (!mounted) {
            return;
          } else if (active['isOutgoing'] == true) {
            final callService = Provider.of<CallService>(context, listen: false);
            if (callService.matchesActiveOutgoingSession(callId)) {
              debugPrint(
                '[AuthWrapper] Appel sortant local actif — conservation CallKit: $callId',
              );
            } else if (await callService.restoreOutgoingFromColdStart(active)) {
              debugPrint(
                '[AuthWrapper] Appel sortant restauré depuis snapshot: $callId',
              );
            } else {
              debugPrint(
                '[AuthWrapper] 🛡 CallKit sortant résiduel → nettoyage: $callId',
              );
              if (callId.isNotEmpty) await EndedCallRegistry.markEnded(callId);
              await CallKitService.instance.endAll(callId: callId);
            }
          } else if (mounted) {
            final callService = Provider.of<CallService>(context, listen: false);
            final isAccepted = active['isAccepted'] == true;
            if (isAccepted) {
              debugPrint('[AuthWrapper]  Appel CallKit déjà accepté → auto-réponse');
              unawaited(callService.acceptIncomingCallFromPush(
                callId:      callId,
                callerId:    active['callerId'] as String,
                callerName:  active['callerName'] as String,
                callerPhoto: active['callerPhoto'] as String?,
                isVideo:     active['isVideo'] as bool,
                roomId:      active['roomId'] as String?,
                sessionKind: active['sessionKind'] as String?,
                mode:        active['mode'] as String?,
              ));
            } else {
              debugPrint('[AuthWrapper]  Appel CallKit actif → écran d\'appel entrant');
              callService.prepareIncomingFromCallKit(
                callId:      callId,
                callerId:    active['callerId'] as String,
                callerName:  active['callerName'] as String,
                callerPhoto: active['callerPhoto'] as String?,
                isVideo:     active['isVideo'] as bool,
                roomId:      active['roomId'] as String?,
                sessionKind: active['sessionKind'] as String?,
                mode:        active['mode'] as String?,
              );
            }
          }
        }
      }

      if (!mounted) return;
      // Refus CallKit persistés (app tuée) : rejouer dès que possible.
      if (authProvider.isLoggedIn) {
        final callService = Provider.of<CallService>(context, listen: false);
        unawaited(callService.flushPendingRejects());
        // Actions de notification en attente (réponse rapide, marquer lu) :
        // rejouées ici aussi, pour le cas où le socket ne monte jamais
        // (`auth:verified` n'arrive pas) alors que l'HTTP passe.
        final chatProvider = Provider.of<ChatProvider>(context, listen: false);
        unawaited(chatProvider.repository.flushPendingNotificationActions());
      }

      try {
        await PushService.init(apiClient, navKey: navigatorKey);
        onCallEndedNotification = ({callId, callerId}) async {
          if (!mounted) return;
          await Provider.of<CallService>(context, listen: false)
              .notifyCallEndedFromExternal(
            callId: callId,
            callerId: callerId,
          );
        };
      } catch (e) {
        debugPrint('[AuthWrapper] PushService init failed: $e');
      }
    } catch (e) {
      debugPrint('[AuthWrapper] ** Erreur init: $e');
      debugPrint('[AuthWrapper] Stack: ${StackTrace.current}');
    }
  }

  /// Appelé sur chaque changement d'AuthProvider (login, logout, refresh user).
  /// Déclenche un bind/unbind des providers dépendants de l'identité.
  void _onAuthChanged() {
    _sessionBindingsChain = _sessionBindingsChain.then((_) async {
      if (!mounted) return;
      await _syncSessionBindings();
    }).catchError((Object e, StackTrace st) {
      debugPrint('[AuthWrapper] _syncSessionBindings échoué: $e');
    });
  }

  /// Aligne l'état des providers (chat, status, admin) sur l'utilisateur
  /// actuellement loggé. Idempotent : ne re-bind pas si déjà bind pour cet ID.
  /// Quelqu'un vient d'utiliser mon code QR. Déjà en contact chez moi :
  /// simple information. Sinon : dialogue oui/non pour l'ajouter en retour —
  /// la rencontre physique doit pouvoir créer le lien dans les deux sens en
  /// deux gestes.
  Future<void> _onQrContactScanned(QrContactScan scan) async {
    debugPrint('[AuthWrapper] scan reçu de ${scan.displayName} '
        '(id=${scan.alanyaID}, mutual=${scan.alreadyMutual}, mounted=$mounted)');
    if (!mounted || scan.alanyaID == 0) return;
    final l10n = context.l10n;
    final messenger = appMessengerKey.currentState;

    if (scan.alreadyMutual) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(l10n.qrScannedMutualInfo(scan.displayName)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    // La note de contexte vaut dans les deux sens : celui qui ajoute en
    // retour vient de vivre la même rencontre que celui qui a scanné.
    final noteCtrl = TextEditingController();
    final accepter = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.qrScanReturnTitle),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.qrScanReturnBody(scan.displayName)),
              const SizedBox(height: 16),
              TextField(
                controller: noteCtrl,
                maxLength: 200,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  hintText: l10n.qrNoteFieldHint,
                  counterText: '',
                  isDense: true,
                  prefixIcon:
                      const Icon(Icons.sticky_note_2_outlined, size: 20),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.qrScanReturnDecline),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.qrScanReturnAccept),
          ),
        ],
      ),
    );
    final note = noteCtrl.text.trim();
    noteCtrl.dispose();
    if (accepter != true || !mounted) return;

    // Capturées ici, sous la garde mounted : le catch s'exécute après des
    // await et ne doit plus toucher au context.
    final api = Provider.of<TalkyApiClient>(context, listen: false);
    final cache = Provider.of<LocalCacheRepository>(context, listen: false);

    try {
      // `viaQr` : les deux directions du lien portent la même origine — la
      // pastille et le filtre « Par QR » valent pour l'ajout en retour aussi.
      final body = await api.addContact(scan.alanyaID, viaQr: true);
      await cache.upsertKnownUser(
        User.fromJson(body),
        preferred: true,
        partial: true,
      );
      if (note.isNotEmpty) {
        await QrContactFlow.saveNote(
          apiClient: api,
          cache: cache,
          user: User.fromJson(body),
          note: note,
        );
      }
      await cache.getPreferredContactsOnce();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(l10n.qrScanAddSuccess(scan.displayName)),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.success,
          duration: const Duration(seconds: 3),
        ),
      );
    } on TalkyException catch (e) {
      // 409 : déjà ajouté entre-temps (double scan, autre appareil) — ce n'est
      // pas un échec du point de vue de l'utilisateur, et sa note reste
      // pertinente : on la pose sur la relation existante.
      final deja = e.statusCode == 409;
      if (deja && note.isNotEmpty) {
        unawaited(QrContactFlow.saveNote(
          apiClient: api,
          cache: cache,
          user: User(
            alanyaID: scan.alanyaID,
            nom: scan.nom,
            pseudo: scan.pseudo,
            alanyaPhone: '',
            email: '',
            idPays: 0,
            avatarUrl: scan.avatarUrl ?? '',
            typeCompte: 0,
            isOnline: false,
            lastSeen: '',
          ),
          note: note,
        ));
      }
      messenger?.showSnackBar(
        SnackBar(
          content: Text(deja
              ? l10n.qrScanAlreadyContact(scan.displayName)
              : l10n.qrScanReturnFailed),
          behavior: SnackBarBehavior.floating,
          backgroundColor: deja ? null : AppColors.error,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e, st) {
      AppLog.e('AuthWrapper', 'Ajout en retour échoué', e, st);
      messenger?.showSnackBar(
        SnackBar(
          content: Text(l10n.qrScanReturnFailed),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// Ajoute le contact désigné par un lien d'identité. Un lien reçu hors
  /// session n'est pas perdu : il reste en attente et sera rejoué par
  /// [_replayPendingQrLink] une fois la connexion faite.
  Future<void> _handleQrIdentityLink(({String kind, String token}) lien) async {
    if (!mounted) return;
    final auth = _authProvider;
    if (auth == null || !auth.isLoggedIn) {
      QrDeepLinkService.instance.stashToken(lien);
      return;
    }
    await QrContactFlow.handleToken(
      kind: lien.kind,
      token: lien.token,
      messenger: ScaffoldMessenger.of(context),
      apiClient: Provider.of<TalkyApiClient>(context, listen: false),
      cache: Provider.of<LocalCacheRepository>(context, listen: false),
      l10n: context.l10n,
    );
  }

  /// Rejoue un lien d'identité reçu avant l'ouverture de session.
  Future<void> _replayPendingQrLink() async {
    final apiClient = Provider.of<TalkyApiClient>(context, listen: false);

    final token = QrDeepLinkService.instance.consumePendingToken();
    if (token != null) await _handleQrIdentityLink(token);

    // Même logique pour un scan arrivé par notification quand personne
    // n'écoutait encore (app lancée par le tap) : l'invitation d'ajout en
    // retour ne doit pas se perdre entre le tap et le premier abonné.
    final scan = apiClient.consumePendingQrContactScan();
    if (scan != null && mounted) await _onQrContactScanned(scan);
  }

  Future<void> _syncSessionBindings() async {
    if (!mounted) return;
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final myId = authProvider.currentUser?.alanyaID;

    // Logout : on était bind, plus d'utilisateur → libère les listeners.
    if (myId == null) {
      if (_boundUserId != null) {
        final endReason = currentSessionEndReason;
        currentSessionEndReason = SessionEndReason.none;
        debugPrint(
          '[AuthWrapper] Logout détecté (reason=$endReason) → unbind providers',
        );
        IncomingShareService.instance.onSessionEnded();
        _removeBackOnlineListener();
        _clearCallLogBindings();
        try {
          Provider.of<PresenceService>(context, listen: false).detach();
        } catch (e) {
          debugPrint('[AuthWrapper] PresenceService.detach échoué: $e');
        }
        try {
          Provider.of<ChatProvider>(context, listen: false).unbind();
          Provider.of<ChatProvider>(context, listen: false).onSocketReadyHook = null;
        } catch (e) {
          debugPrint('[AuthWrapper] ChatProvider.unbind échoué: $e');
        }
        try {
          Provider.of<StatusProvider>(context, listen: false).unbind();
        } catch (e) {
          debugPrint('[AuthWrapper] StatusProvider.unbind échoué: $e');
        }
        // Révocation à distance : c'est bien une décision de l'utilisateur,
        // le cache local part avec, comme pour un logout explicite.
        if (endReason == SessionEndReason.explicitLogout ||
            endReason == SessionEndReason.revokedRemotely) {
          await _clearLocalSession();
        }
        _boundUserId = null;
      }
      return;
    }

    // Déjà bind sur le même utilisateur, rien à faire — sauf si le chat a été
    // débindé entre-temps (logout/re-login rapide pendant le vidage local).
    if (myId == _boundUserId) {
      final chatBound = Provider.of<ChatProvider>(context, listen: false)
          .repository
          .myId;
      if (chatBound != 0) return;
      debugPrint(
        '[AuthWrapper] myId=$_boundUserId mais chat débindé → re-bind',
      );
    }

    // Changement d'utilisateur : on libère l'ancien bind avant le neuf.
    if (_boundUserId != null && _boundUserId != myId) {
      _clearCallLogBindings();
      try {
        Provider.of<ChatProvider>(context, listen: false).unbind();
        Provider.of<StatusProvider>(context, listen: false).unbind();
        // Repart d'un état de présence vierge pour le nouveau compte.
        Provider.of<PresenceService>(context, listen: false).detach();
      } catch (e) {
        debugPrint('[AuthWrapper] unbind avant switch user: $e');
      }
      await _clearLocalSession();
      if (!mounted) return;
    }

    _boundUserId = myId;
    debugPrint('[AuthWrapper] Bind providers pour userID=$myId');

    // Lien d'identité reçu avant l'ouverture de session (app démarrée par le
    // lien, ou utilisateur qui devait d'abord se connecter) : c'est maintenant
    // qu'on peut l'honorer.
    unawaited(_replayPendingQrLink());

    if (!mounted) return;
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    final statusProvider = Provider.of<StatusProvider>(context, listen: false);
    final adminProvider = Provider.of<AdminProvider>(context, listen: false);
    final apiClient = Provider.of<TalkyApiClient>(context, listen: false);
    final syncService = Provider.of<RealtimeSyncService>(context, listen: false);
    final presence = Provider.of<PresenceService>(context, listen: false);

    unawaited(PushService.syncTokenWithBackend());
    unawaited(_loadNotificationPrefs(apiClient));
    unawaited(_syncAccountSettings(apiClient));

    // Une sauvegarde à restaurer ? La question se pose ICI, avant de lier quoi
    // que ce soit. Le serveur répond sans qu'aucun compte Google ne soit
    // demandé : c'est la métadonnée déclarée à chaque sauvegarde réussie.
    if (await _shouldOfferRestore(apiClient)) return;

    try {
      await chatProvider.bind(myId);
      if (mounted) {
        final cache = Provider.of<LocalCacheRepository>(context, listen: false);
        cache.syncPreferredContacts();
        cache.syncCalls(myId: myId);
        cache.syncMeetings();
        cache.purgeExpiredStatuses();
        _bindCallLogListener(myId);
      }
    } catch (e) {
      debugPrint('[AuthWrapper] ChatProvider.bind échoué: $e');
    }

    try {
      await statusProvider.bind(myId);
    } catch (e) {
      debugPrint('[AuthWrapper] StatusProvider.bind échoué: $e');
    }

    // Connecter le socket seulement après les listeners chat/status :
    // sinon `message:received` / `auth:verified` peuvent être perdus.
    apiClient.setPendingMessagesCallback(
      () => chatProvider.repository.hasSyncPending(),
    );
    // Avant connectSocket : le résolveur doit être en place quand le premier
    // `auth:verified` arrive, sinon la session s'annoncerait en ligne par
    // défaut même app en arrière-plan.
    presence.attach();
    apiClient.connectSocket();

    chatProvider.onSocketReadyHook = syncService.refreshStatuses;

    if (mounted) {
      _removeBackOnlineListener();
      final connectivity =
          Provider.of<ConnectivityProvider>(context, listen: false);
      final cache =
          Provider.of<LocalCacheRepository>(context, listen: false);
      _connectivityForListener = connectivity;
      _onBackOnline = () {
        debugPrint('[AuthWrapper] Réseau revenu → catch-up + caches');
        unawaited(apiClient.ensureSocketReady());
        unawaited(syncService.catchUp());
        cache.syncPreferredContacts();
        cache.syncCalls(myId: myId);
        cache.syncMeetings();
      };
      connectivity.addBackOnlineListener(_onBackOnline!);
    }

    // Réservé aux comptes admin : /admin/stats déclenche ~10 agrégations
    // lourdes côté serveur (dont des COUNT(*) sur `message`). Appelé sans
    // garde, chaque login utilisateur payait ce coût pour un 403 avalé.
    if (AdminProvider.isAdmin(authProvider.currentUser)) {
      try {
        await adminProvider.loadStats();
      } catch (e) {
        debugPrint('[AuthWrapper] AdminProvider.loadStats échoué: $e');
      }
    }

    IncomingShareService.instance.onSessionReady();
  }

  /// Efface toutes les données locales liées à la session utilisateur.
  Future<void> _clearLocalSession() async {
    if (!mounted) return;
    debugPrint('[AuthWrapper] Vidage cache local session');
    final chat = Provider.of<ChatProvider>(context, listen: false);
    final cache = Provider.of<LocalCacheRepository>(context, listen: false);
    final hidden = Provider.of<LocalHiddenStore>(context, listen: false);
    final status = Provider.of<StatusProvider>(context, listen: false);
    final privacy = Provider.of<PrivacyPrefsService>(context, listen: false);
    final biometric = Provider.of<BiometricLockService>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final userId = auth.currentUser?.alanyaID;
    try {
      await chat.clearLocalSession();
    } catch (e) {
      debugPrint('[AuthWrapper] clearLocalSession chat échoué: $e');
    }
    try {
      await cache.clearSession();
    } catch (e) {
      debugPrint('[AuthWrapper] clearSession cache échoué: $e');
    }
    try {
      await hidden.clearAll();
    } catch (e) {
      debugPrint('[AuthWrapper] LocalHiddenStore.clearAll échoué: $e');
    }
    // Files déposées par la couche native : les actions et accusés d'un compte
    // ne doivent jamais être rejoués avec le token d'un autre.
    try {
      await PendingNotificationActionStore.clear();
      await PendingDeliveryAckStore.clear();
    } catch (e) {
      debugPrint('[AuthWrapper] purge files natives échouée: $e');
    }
    try {
      await status.clearSessionPreferences();
    } catch (e) {
      debugPrint('[AuthWrapper] clearSessionPreferences statuts échoué: $e');
    }
    try {
      await BadgeSyncService.clear();
      await NotificationPrefsCache.clear();
      await privacy.clear();
      await biometric.clear();
      if (userId != null) {
        await OnboardingService().clear(userId);
      }
      await PushService.onSessionEnded();
    } catch (e) {
      debugPrint('[AuthWrapper] clear notification session échoué: $e');
    }
  }

  Future<void> _syncAccountSettings(TalkyApiClient api) async {
    if (!mounted) return;
    try {
      final theme = Provider.of<ThemeController>(context, listen: false);
      final locale = Provider.of<LocaleController>(context, listen: false);
      final sync = Provider.of<AppSettingsSyncService>(context, listen: false);
      final privacy =
          Provider.of<PrivacyPrefsService>(context, listen: false);
      await sync.syncFromServer(theme: theme, locale: locale);
      await privacy.syncFromServer();
    } catch (e) {
      debugPrint('[AuthWrapper] syncAccountSettings échoué: $e');
    }
  }

  Future<void> _loadNotificationPrefs(TalkyApiClient api) async {
    try {
      await NotificationPrefsCache.load();
      final prefs = await api.getNotificationPrefs();
      await NotificationPrefsCache.applyFromServer(prefs);
    } catch (e) {
      debugPrint('[AuthWrapper] loadNotificationPrefs échoué: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        debugPrint('[AuthWrapper] build - isInitialized=${auth.isInitialized}, '
            'isLoggedIn=${auth.isLoggedIn}');
        if (!auth.isInitialized) {
          // Couverture blanche le temps du cache local ; le splash natif
          // reste affiché grâce à FlutterNativeSplash.preserve (pas de spinner).
          return const Scaffold(
            backgroundColor: Color(0xFFFFFFFF),
            body: SizedBox.shrink(),
          );
        }
        return BiometricLockOverlay(
          sessionActive: auth.isLoggedIn,
          child: auth.isLoggedIn
              // L'écran de restauration ne passe pas par ici mais par la
              // navigation, voir `_offerRestore` : la question se pose au
              // milieu d'une séquence asynchrone, pas à la reconstruction.
              ? PostAuthGate(key: ValueKey(auth.currentUser?.alanyaID ?? 0))
              : const LoginScreen(),
        );
      },
    );
  }
}