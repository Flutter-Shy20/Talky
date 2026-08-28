/// États micro/caméra d'un appel de groupe reçus avant leur auteur.
///
/// `group:mute_state` et `group:video_state` n'étaient appliqués que si leur
/// auteur figurait déjà au roster ; sinon ils étaient jetés en silence. Le
/// serveur ne les réémet pas, et l'émetteur n'a aucun moyen de savoir qu'on les
/// a perdus : l'affichage restait faux jusqu'à sa prochaine bascule de micro.
///
/// Ces états arrivent avant le roster plus souvent qu'il n'y paraît — le temps
/// que `group_participants` fasse l'aller-retour et que les noms se résolvent
/// par l'API, un participant a largement le temps de couper son micro.
library;

/// Ce qui était retenu pour un participant : `null` quand rien ne l'était.
typedef GroupMediaState = ({bool? isMuted, bool? isVideoOn});

class PendingGroupMediaStates {
  final Map<String, bool> _muted = {};
  final Map<String, bool> _videoOn = {};

  bool get isEmpty => _muted.isEmpty && _videoOn.isEmpty;

  /// Les participants dont un état attend d'être appliqué.
  Set<String> get userIds => {..._muted.keys, ..._videoOn.keys};

  void recordMuted(String userId, bool isMuted) {
    if (userId.isEmpty) return;
    _muted[userId] = isMuted;
  }

  void recordVideoOn(String userId, bool isVideoOn) {
    if (userId.isEmpty) return;
    _videoOn[userId] = isVideoOn;
  }

  /// Retire et rend les états retenus pour [userId].
  ///
  /// Retirer plutôt que lire : un état appliqué ne doit pas l'être deux fois,
  /// sinon il écraserait une bascule plus récente à la prochaine arrivée au
  /// roster — ce qui arrive à chaque reprise de la salle après coupure.
  GroupMediaState take(String userId) => (
        isMuted: _muted.remove(userId),
        isVideoOn: _videoOn.remove(userId),
      );

  /// Oublie ce qui était retenu pour [userId] — il a quitté l'appel.
  void forget(String userId) {
    _muted.remove(userId);
    _videoOn.remove(userId);
  }

  void clear() {
    _muted.clear();
    _videoOn.clear();
  }
}
