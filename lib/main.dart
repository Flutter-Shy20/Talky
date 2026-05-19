import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'core/services/call_service.dart';
import 'core/services/callkit_service.dart';
import 'core/services/meeting_service.dart';
import 'core/services/push_service.dart';
import 'firebase_options.dart';
import 'features/authentification/login_screen.dart';
import 'features/home/home_screen.dart';
import 'talky_api_client.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[Main] 🚀 Application démarrée');

  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await CallKitService.instance.init();
    debugPrint('[Main] Firebase + CallKit initialisés');
  } catch (e) {
    debugPrint('[Main] ⚠️ Init Firebase échouée — push désactivé: $e');
  }

  runApp(
    const riverpod.ProviderScope(  // ← notre ajout Riverpod
      child: TalkyApp(),
    ),
  );
}

class TalkyApp extends StatelessWidget {
  const TalkyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final apiClient = TalkyApiClient();
    return MultiProvider(
      providers: [
        Provider<TalkyApiClient>.value(value: apiClient),
        ChangeNotifierProvider(create: (_) => AuthProvider(apiClient: apiClient)),
        ChangeNotifierProvider(create: (_) => CallService(apiClient: apiClient)),
        ChangeNotifierProvider(create: (_) => MeetingService(apiClient: apiClient)),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Talky',
        theme: ThemeData(
          primarySwatch: Colors.indigo,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          scaffoldBackgroundColor: Colors.white,
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            elevation: 0,
            iconTheme: IconThemeData(color: Colors.black),
            titleTextStyle: TextStyle(
              color: Colors.black,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          useMaterial3: true,
        ),
        home: const AuthWrapper(),
      ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  @override
  void initState() {
    super.initState();
    debugPrint('[AuthWrapper] initState - Lancement de init()');
    Future.microtask(() async {
      try {
        final apiClient = Provider.of<TalkyApiClient>(context, listen: false);
        await Provider.of<AuthProvider>(context, listen: false).init();
        debugPrint('[AuthWrapper] ✅ init() complété');

        try {
          await PushService.init(apiClient);
        } catch (e) {
          debugPrint('[AuthWrapper] PushService init failed: $e');
        }

        void dispatch(IncomingCallAction action) {
          if (!mounted) return;
          final callService = Provider.of<CallService>(context, listen: false);
          switch (action.action) {
            case IncomingCallActionType.accept:
              callService.acceptIncomingCallFromPush(
                callId:      action.callId,
                callerId:    action.callerId,
                callerName:  action.callerName,
                callerPhoto: action.callerPhoto,
                isVideo:     action.isVideo,
                roomId:      action.roomId,
              );
              break;
            case IncomingCallActionType.decline:
            case IncomingCallActionType.timeout:
            case IncomingCallActionType.ended:
              callService.rejectIncomingCallFromPush(
                callerId: action.callerId,
              );
              break;
          }
        }

        CallKitService.instance.actions.listen(dispatch);

        final pending = CallKitService.instance.consumePendingAction();
        if (pending != null) {
          debugPrint('[AuthWrapper] 🎯 Pending CallKit action: ${pending.action}');
          dispatch(pending);
        }
      } catch (e) {
        debugPrint('[AuthWrapper] ❌ Erreur init: $e');
        debugPrint('[AuthWrapper] Stack: ${StackTrace.current}');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        if (!auth.isInitialized) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return auth.isLoggedIn ? const HomeScreen() : const LoginScreen();
      },
    );
  }
}