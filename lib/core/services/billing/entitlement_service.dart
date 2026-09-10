import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../talky_api_client.dart';
import 'entitlements.dart';

/// Droits d'accès Alanya Plus : cache local et synchronisation serveur.
///
/// Le serveur calcule, le téléphone lit. Les droits arrivent avec `/auth/me`
/// (via [AuthProvider]) et se rafraîchissent par `GET /billing/me` quand
/// `validUntil` est dépassé. Sans réponse serveur, le dernier état connu
/// s'applique — et sans aucun état connu, tout est permis.
class EntitlementService extends ChangeNotifier {
  EntitlementService({required TalkyApiClient api}) : _api = api {
    _instance = this;
  }

  static const _cacheKey = 'plus_entitlements_json_v1';

  static EntitlementService? _instance;

  /// Pour les services sans contexte (traduction, sonneries) : même instance
  /// que celle exposée par le `MultiProvider`.
  static EntitlementService? get maybeInstance => _instance;

  /// Lecture synchrone. Sans service (tests, démarrage), rien n'est fermé.
  static bool allows(PlusFeature feature) =>
      _instance?.has(feature) ?? true;

  final TalkyApiClient _api;
  Entitlements _current = Entitlements.unrestricted;
  bool _refreshing = false;

  Entitlements get current => _current;

  bool has(PlusFeature feature) => _current.has(feature);

  Future<void> loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return;
      _current = Entitlements.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
      notifyListeners();
    } catch (e) {
      debugPrint('[Entitlements] cache illisible : $e');
    }
  }

  /// Le profil `/auth/me` : sa clé `entitlements`, ou rien (serveur ancien).
  Future<void> applyFromProfile(Map<String, dynamic> me) =>
      apply(me['entitlements']);

  Future<void> apply(Object? raw) async {
    _current = raw is Map
        ? Entitlements.fromJson(Map<String, dynamic>.from(raw))
        : Entitlements.unrestricted;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_current.known) {
        await prefs.setString(_cacheKey, jsonEncode(_current.toJson()));
      } else {
        await prefs.remove(_cacheKey);
      }
    } catch (e) {
      debugPrint('[Entitlements] cache non écrit : $e');
    }
  }

  /// Relit les droits. Un échec (réseau, serveur ancien) garde l'état connu.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await apply(await _api.getMyEntitlements());
    } catch (e) {
      debugPrint('[Entitlements] rafraîchissement impossible : $e');
    } finally {
      _refreshing = false;
    }
  }

  Future<void> refreshIfStale() async {
    if (_current.isStale(DateTime.now())) await refresh();
  }

  /// À la déconnexion : les droits d'un compte ne passent pas au suivant.
  Future<void> clear() async {
    _current = Entitlements.unrestricted;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
    } catch (_) {}
  }
}
