import 'package:connectivity_plus/connectivity_plus.dart';

/// Wrapper léger autour de connectivity_plus.
/// Considère "online" toute interface autre que `none`.
class ConnectivityService {
  final Connectivity _c = Connectivity();

  Stream<bool> get hasNetwork => _c.onConnectivityChanged.map(_anyConnected);

  Future<bool> get currentNetwork async {
    final r = await _c.checkConnectivity();
    return _anyConnected(r);
  }

  /// `true` si la connexion actuelle ne se paie pas au volume.
  ///
  /// Sert au téléchargement automatique des médias reçus : l'activer par
  /// défaut n'est acceptable que s'il ne consomme pas le forfait de
  /// l'utilisateur sans qu'il l'ait demandé.
  ///
  /// Wi-Fi et Ethernet comptent, les données mobiles non. Les autres
  /// interfaces (VPN, bluetooth, `other`) sont traitées comme mesurées : en
  /// cas de doute sur ce qu'une connexion coûte, on s'abstient. Hors ligne
  /// renvoie `false` — il n'y a alors rien à télécharger de toute façon.
  Future<bool> get currentIsUnmetered async {
    final r = await _c.checkConnectivity();
    return _unmetered(r);
  }

  static bool _anyConnected(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  static bool _unmetered(List<ConnectivityResult> results) => results.any(
        (r) => r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet,
      );
}
