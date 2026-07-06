// Connexion et gestion des events Socket.IO (part of talky_api_client.dart).
part of '../talky_api_client.dart';

extension SocketApi on TalkyApiClient {
  void connectSocket() {
    if (_accessToken == null) return;
    if (_socket?.connected == true) return;

    // Le segment de chemin de `socketUrl` (ex: `/tmp/`) n'est PAS un préfixe
    // de requête pour la lib socket.io : passé tel quel comme URL de
    // connexion, il est interprété comme un NAMESPACE Socket.IO (`/tmp`), qui
    // n'existe pas côté serveur (seul le namespace par défaut `/` est
    // enregistré) → rejeté avec "Invalid namespace", après un transport bas
    // niveau qui, lui, s'ouvre bien (d'où `onReconnect` qui se déclenche sans
    // jamais `onConnect` : incident du 2026-07-06). Le chemin HTTP réel du
    // handshake se configure exclusivement via l'option `path` ci-dessous ;
    // l'URL de connexion doit rester seulement l'origine (schéma+hôte+port).
    final socketUri = Uri.parse(TalkyApiClient.socketUrl);
    final socketOrigin = socketUri.origin;
    final socketPathPrefix = socketUri.path;
    final socketPath =
        '${socketPathPrefix.endsWith('/') ? socketPathPrefix : '$socketPathPrefix/'}socket.io/';

    _socket = io.io(socketOrigin, <String, dynamic>{
      'path': socketPath,
      'transports': ['websocket'],
      'autoConnect': false,
      'reconnection': true,
      'reconnectionDelay': 2000,
      'reconnectionAttempts': 10,
    });

    _socket!.onConnect((_) {
      debugPrint('[Socket] Connecté — envoi auth:login');
      // !! AUTH SOCKET obligatoire — sinon tous les handlers ignorent les events
      _socket!.emit(SocketEvents.authLogin, {'token': _accessToken});
    });

    _socket!.on(SocketEvents.authVerified, (data) {
      debugPrint('[Socket] Authentifié: ${data['alanyaID']}');
      _isSocketAuthVerified = true;
      // Signaler présence en ligne
      _socket!.emit(SocketEvents.presenceOnline, {'userID': data['alanyaID']});
    });

    _socket!.on(SocketEvents.authError, (data) {
      debugPrint('[Socket] Erreur auth: ${data['message']}');
      _isSocketAuthVerified = false;
    });

    _socket!.on(SocketEvents.authConflict, (data) {
      debugPrint('[Socket] Conflit connexion: ${data['message']}');
      _isSocketAuthVerified = false;
    });

    _socket!.onDisconnect((_) {
      debugPrint('[Socket] Déconnecté');
      _isSocketAuthVerified = false;
    });
    _socket!.onError((err) => debugPrint('[Socket] Erreur: $err'));
    _socket!.onReconnect((_) {
      debugPrint('[Socket] Reconnecté — ré-auth');
      _isSocketAuthVerified = false;
      _socket!.emit(SocketEvents.authLogin, {'token': _accessToken});
    });

    // Ré-attache au socket fraîchement créé les listeners externes déjà
    // enregistrés via `onSocketEvent` (utile après un logout/login : les modules
    // clients gardent leurs callbacks via _socketListeners, mais le _socket a
    // été détruit puis recréé).
    _socketListeners.forEach((event, callbacks) {
      for (final cb in callbacks) {
        _socket!.on(event, cb);
      }
    });

    _socket!.connect();
  }

  void disconnectSocket() {
    _isSocketAuthVerified = false;
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _socketListeners.clear();
  }

  void sendSocketEvent(String event, dynamic data) {
    if (!isSocketReady) {
      debugPrint('[Socket] ** emit "$event" différé (socket non prêt — connected=$isSocketConnected, auth=$_isSocketAuthVerified)');
      return;
    }
    _socket!.emit(event, data);
  }

  void onSocketEvent(String event, Function(dynamic) callback) {
    // Registre pour ré-attacher au prochain `connectSocket()` (cas logout/login
    // où `_socket` est recréé). socket.io conserve ses listeners au travers des
    // reconnexions auto donc on n'a pas besoin de re-binder à chaque fois.
    final listeners = _socketListeners.putIfAbsent(event, () => []);
    if (listeners.contains(callback)) return;
    listeners.add(callback);
    debugPrint('[Socket] 📌 Listener enregistré pour "$event"');

    // Attache directement au socket s'il existe : `.on` accepte avant connect
    // et la livraison se déclenche dès qu'un event arrive (post auth:verified).
    _socket?.on(event, callback);
  }

  void offSocketEvent(String event) {
    _socketListeners.remove(event);
    _socket?.off(event);
  }

  /// Retire un callback précis pour un event donné, sans détruire les autres
  /// listeners du même event. Utilisé par les écrans (chat_detail) qui ne
  /// doivent pas évincer les listeners globaux (chat_repository, etc.) en se
  /// fermant.
  void removeSocketListener(String event, Function(dynamic) callback) {
    final list = _socketListeners[event];
    if (list != null) {
      list.remove(callback);
      if (list.isEmpty) _socketListeners.remove(event);
    }
    _socket?.off(event, callback);
  }
}
