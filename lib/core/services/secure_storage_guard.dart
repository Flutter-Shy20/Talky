import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Options Android communes à tous les magasins sécurisés de l'app.
///
/// `encryptedSharedPreferences` chiffre via `EncryptedSharedPreferences`, dont
/// la clé maîtresse vit dans le Keystore. `resetOnError` évite qu'une lecture
/// impossible ne remonte une `PlatformException` brute jusqu'à l'écran de
/// connexion : le plugin purge le magasin à la place.
///
/// Attention : quand cette purge se déclenche, le plugin Android répond
/// `"Data has been reset"` **y compris à un `read`**
/// (`FlutterSecureStoragePlugin.java` : `result.success("Data has been reset")`).
/// Sans filtrage, `getAccessToken()` renverrait cette chaîne — un jeton non nul,
/// donc une app qui se croit connectée avec un jeton bidon. C'est le rôle de
/// [SecureStorageGuard.readString].
const AndroidOptions kSecureStorageAndroidOptions = AndroidOptions(
  encryptedSharedPreferences: true,
  resetOnError: true,
);

/// Lectures et écritures tolérantes au magasin chiffré devenu illisible.
///
/// Le cas nominal est traité côté natif, avant le démarrage de Flutter
/// (`SecureStorageRepair.verifyAndRepair`, appelé dans `Application.onCreate`).
/// Ce garde couvre le résidu : un Keystore invalidé *pendant* que l'app tourne,
/// typiquement l'ajout ou le retrait du verrouillage d'écran.
///
/// Il ne peut pas rétablir le magasin pour la session en cours — le drapeau
/// `failedToUseEncryptedSharedPreferences` du plugin est collant pour tout le
/// process. Il fait donc deux choses : rendre la lecture inoffensive (null, donc
/// « pas de session » et non un plantage), et demander au natif une purge qui
/// prendra effet au prochain démarrage.
class SecureStorageGuard {
  SecureStorageGuard._();

  static const MethodChannel _channel =
      MethodChannel('com.alanya237.alanya/secure_storage_repair');

  /// Sentinelle renvoyée par le plugin Android quand `resetOnError` a purgé.
  static const String resetSentinel = 'Data has been reset';

  /// Une seule réparation par process : la purge est globale, la répéter à
  /// chaque clé ne ferait qu'ajouter des allers-retours inutiles.
  static bool _repairRequested = false;

  /// True dès qu'une lecture a constaté que le magasin était illisible.
  static bool get storeWasReset => _repairRequested;

  @visibleForTesting
  static void resetStateForTest() => _repairRequested = false;

  /// Lecture qui ne remonte jamais d'erreur : `null` signifie « absent ou
  /// illisible », ce qui ramène l'app à l'écran de connexion au lieu d'y
  /// afficher une pile d'appels.
  static Future<String?> readString(
    FlutterSecureStorage storage,
    String key,
  ) async {
    try {
      final value = await storage.read(key: key);
      if (value == resetSentinel) {
        // resetOnError vient de vider le magasin : le plugin a bien effacé le
        // fichier, mais pas l'alias Keystore fautif. Sans la réparation native,
        // l'échec se reproduirait à chaque démarrage.
        debugPrint('[SecureStorage] magasin purgé par resetOnError (clé "$key")');
        await requestRepair();
        return null;
      }
      return value;
    } on PlatformException catch (e) {
      debugPrint('[SecureStorage] lecture "$key" impossible : ${e.message}');
      await requestRepair();
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Écriture : demande la réparation si le magasin est cassé, puis laisse
  /// l'erreur remonter. Un jeton qu'on croit enregistré alors qu'il ne l'est
  /// pas serait pire qu'un échec visible.
  static Future<void> writeString(
    FlutterSecureStorage storage,
    String key,
    String value,
  ) async {
    try {
      await storage.write(key: key, value: value);
    } on PlatformException catch (e) {
      debugPrint('[SecureStorage] écriture "$key" impossible : ${e.message}');
      await requestRepair();
      rethrow;
    }
  }

  /// Suppression best-effort : sur un magasin déjà illisible, échouer à
  /// effacer n'apporte rien à l'appelant.
  static Future<void> deleteKey(
    FlutterSecureStorage storage,
    String key,
  ) async {
    try {
      await storage.delete(key: key);
    } on PlatformException catch (e) {
      debugPrint('[SecureStorage] suppression "$key" impossible : ${e.message}');
      await requestRepair();
    } on MissingPluginException {
      // Plateforme sans magasin natif (tests, web).
    }
  }

  /// Demande au natif d'effacer le magasin et l'alias Keystore. Sans effet sur
  /// la session en cours (voir la doc de la classe) : la purge est appliquée au
  /// prochain démarrage.
  static Future<bool> requestRepair() async {
    if (_repairRequested) return false;
    _repairRequested = true;
    try {
      final repaired = await _channel.invokeMethod<bool>('repair');
      debugPrint('[SecureStorage] réparation native demandée (ok=$repaired)');
      return repaired ?? false;
    } on MissingPluginException {
      // iOS / tests : pas de pont natif.
      return false;
    } catch (e) {
      debugPrint('[SecureStorage] réparation native échouée : $e');
      return false;
    }
  }
}
