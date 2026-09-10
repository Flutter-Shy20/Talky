import 'dart:convert';

import 'backup_service.dart';

/// Récupère les clés de sauvegarde auprès du serveur.
///
/// ── Le contrat attendu côté serveur ──
///
/// | Route | Rôle |
/// |---|---|
/// | `GET /backup/key` | Version courante et sa clé — pour écrire |
/// | `GET /backup/key/:kid` | Clé d'une version donnée — pour relire une archive ancienne |
///
/// Réponse : `{ "kid": 1, "key": "<32 octets en base64>" }`.
///
/// Côté base, une table `backup_key_secrets(kid, secret, created_at,
/// retired_at)` dont **aucune ligne n'est jamais supprimée** : retirer une
/// version signifie cesser d'écrire avec, jamais cesser de servir. La clé
/// rendue est dérivée du secret de la version et de l'`alanyaID`, si bien
/// qu'une même version produit une clé différente pour chaque compte.
///
/// Les deux routes sont authentifiées comme le reste de l'API, **journalisées
/// et limitées en débit** : puisque le serveur peut déchiffrer, ce point
/// d'accès est le joyau de la couronne. La trace d'audit fait la différence
/// entre « Alanya peut déchiffrer », phrase inquiétante, et « Alanya peut
/// déchiffrer, et chaque accès laisse une trace », phrase défendable.
class ServerBackupKeyProvider implements BackupKeyProvider {
  /// Exécute une requête authentifiée et rend le corps JSON décodé.
  ///
  /// Injecté plutôt que d'importer le client d'API : ce fichier reste ainsi
  /// éprouvable sans réseau, et le jour où le transport change, il ne bouge
  /// pas.
  final Future<String> Function(String path) get;

  const ServerBackupKeyProvider(this.get);

  @override
  Future<BackupKey> current() => _fetch('/backup/key');

  @override
  Future<BackupKey> byKid(int kid) => _fetch('/backup/key/$kid');

  Future<BackupKey> _fetch(String path) async {
    final String body;
    try {
      body = await get(path);
    } catch (e) {
      // Réseau coupé, serveur indisponible, route absente : la sauvegarde ne
      // peut pas avoir lieu, et le dire est préférable à chiffrer avec une
      // clé de repli qui n'aurait aucune valeur de sécurité.
      throw BackupKeyUnavailable('$e');
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw const BackupKeyUnavailable('réponse illisible');
    }

    final kid = json['kid'];
    final key = json['key'];
    if (kid is! int || key is! String || key.isEmpty) {
      throw const BackupKeyUnavailable('réponse incomplète');
    }

    final bytes = base64Decode(key);
    if (bytes.length != 32) {
      // AES-256 : une clé d'une autre taille signale un serveur mal configuré,
      // et l'accepter produirait des archives illisibles par la suite.
      throw BackupKeyUnavailable('clé de ${bytes.length} octets au lieu de 32');
    }
    return BackupKey(kid, bytes);
  }
}

/// Le serveur n'a pas pu fournir la clé demandée.
///
/// Distincte d'un échec de chiffrement : ici rien n'a été tenté, et l'écran
/// doit inviter à réessayer plutôt qu'à s'inquiéter de ses données.
class BackupKeyUnavailable implements Exception {
  final String reason;
  const BackupKeyUnavailable(this.reason);

  @override
  String toString() => 'BackupKeyUnavailable($reason)';
}
