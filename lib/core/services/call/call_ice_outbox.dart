/// Rejeu des candidats ICE sortants gardés pendant la sonnerie.
///
/// L'appelant rassemble ses candidats une à deux secondes après avoir créé son
/// offre, donc pendant que le téléphone d'en face sonne. Le relais serveur les
/// jetait alors, faute d'appareil actif où les router — et `onIceCandidate` ne
/// repasse jamais par un candidat déjà émis. Le destinataire décrochait sans un
/// seul candidat distant : aucune paire à tester, une allocation TURN sans
/// permission installée, donc sourde. L'appel restait muet jusqu'à ce qu'un ICE
/// restart les embarque dans le SDP, une vingtaine de secondes plus tard.
///
/// D'où cette copie locale, rejouée au décrochage.
library;

/// Un candidat gardé : sa génération ICE et la charge utile telle qu'émise.
typedef OutgoingIceEntry = ({int generation, Map<String, dynamic> payload});

/// Résultat d'un rejeu : ce qui est parti, et ce qui reste à retenter.
typedef IceReplayOutcome = ({int sent, List<OutgoingIceEntry> remaining});

/// Rejoue [outbox] pour la génération [generation] via [send].
///
/// Deux règles, et la seconde est celle qui manquait :
///
/// — Une entrée d'une génération périmée est **oubliée**. Un ICE restart a
///   depuis renuméroté la négociation, et le pair rejetterait ces candidats.
///
/// — Une entrée que [send] n'a pas réussi à émettre est **conservée**. Vider la
///   boîte sans regarder ce qui était réellement parti perdait définitivement
///   les candidats quand le socket était tombé juste avant — et c'est
///   exactement le silence de vingt-cinq secondes que ce rejeu existe pour
///   éviter.
IceReplayOutcome replayOutgoingIce({
  required List<OutgoingIceEntry> outbox,
  required int generation,
  required bool Function(Map<String, dynamic> payload) send,
}) {
  var sent = 0;
  final remaining = <OutgoingIceEntry>[];
  for (final entry in outbox) {
    if (entry.generation != generation) continue;
    if (send(entry.payload)) {
      sent += 1;
    } else {
      remaining.add(entry);
    }
  }
  return (sent: sent, remaining: remaining);
}
