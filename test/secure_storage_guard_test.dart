import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/secure_storage_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const storageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const repairChannel =
      MethodChannel('com.alanya237.alanya/secure_storage_repair');

  const storage = FlutterSecureStorage(aOptions: kSecureStorageAndroidOptions);

  late Map<String, Object?> memory;
  late List<String> repairCalls;

  void mockStorage(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, handler);
  }

  setUp(() {
    memory = {};
    repairCalls = [];
    SecureStorageGuard.resetStateForTest();
    mockStorage((call) async {
      switch (call.method) {
        case 'read':
          return memory[call.arguments['key'] as String];
        case 'write':
          memory[call.arguments['key'] as String] =
              call.arguments['value'] as String;
          return null;
        case 'delete':
          memory.remove(call.arguments['key'] as String);
          return null;
        default:
          return null;
      }
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(repairChannel, (call) async {
      repairCalls.add(call.method);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(storageChannel, null)
      ..setMockMethodCallHandler(repairChannel, null);
  });

  test('les options Android activent le magasin chiffré et resetOnError', () {
    final map = kSecureStorageAndroidOptions.toMap();
    expect(map['encryptedSharedPreferences'], 'true');
    expect(map['resetOnError'], 'true');
  });

  test('une lecture normale traverse le garde sans réparation', () async {
    memory['access_token'] = 'jwt-123';
    expect(
      await SecureStorageGuard.readString(storage, 'access_token'),
      'jwt-123',
    );
    expect(repairCalls, isEmpty);
    expect(SecureStorageGuard.storeWasReset, isFalse);
  });

  test(
    'la sentinelle de resetOnError ne devient jamais un jeton',
    () async {
      // Le plugin Android répond `result.success("Data has been reset")` à un
      // `read` quand resetOnError a purgé le magasin. Non filtrée, cette
      // chaîne serait un access token non nul : l'app se croirait connectée.
      memory['access_token'] = SecureStorageGuard.resetSentinel;

      final value = await SecureStorageGuard.readString(storage, 'access_token');

      expect(value, isNull);
      expect(repairCalls, ['repair']);
      expect(SecureStorageGuard.storeWasReset, isTrue);
    },
  );

  test('un BAD_DECRYPT rend null et demande la réparation', () async {
    mockStorage((call) async {
      if (call.method == 'read') {
        throw PlatformException(
          code: 'Exception encountered',
          message: 'read',
          details: 'javax.crypto.BadPaddingException: error:1e000065:Cipher '
              'functions:OPENSSL_internal:BAD_DECRYPT',
        );
      }
      return null;
    });

    expect(await SecureStorageGuard.readString(storage, 'access_token'), isNull);
    expect(repairCalls, ['repair']);
  });

  test('la réparation native n’est demandée qu’une fois par process', () async {
    mockStorage((call) async {
      if (call.method == 'read') {
        throw PlatformException(code: 'Exception encountered', message: 'read');
      }
      return null;
    });

    await SecureStorageGuard.readString(storage, 'access_token');
    await SecureStorageGuard.readString(storage, 'refresh_token');
    await SecureStorageGuard.readString(storage, 'user_data');

    expect(repairCalls, ['repair']);
  });

  test('une écriture impossible remonte l’erreur après réparation', () async {
    mockStorage((call) async {
      if (call.method == 'write') {
        throw PlatformException(code: 'Exception encountered', message: 'write');
      }
      return null;
    });

    await expectLater(
      SecureStorageGuard.writeString(storage, 'access_token', 'jwt'),
      throwsA(isA<PlatformException>()),
    );
    expect(repairCalls, ['repair']);
  });

  test('une suppression impossible reste silencieuse', () async {
    mockStorage((call) async {
      if (call.method == 'delete') {
        throw PlatformException(code: 'Exception encountered', message: 'delete');
      }
      return null;
    });

    await SecureStorageGuard.deleteKey(storage, 'access_token');
    expect(repairCalls, ['repair']);
  });

  test('sans pont natif, le garde reste inoffensif', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(repairChannel, null);
    memory['access_token'] = SecureStorageGuard.resetSentinel;

    expect(await SecureStorageGuard.readString(storage, 'access_token'), isNull);
  });
}
