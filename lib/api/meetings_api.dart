// Endpoints réunions (part of talky_api_client.dart).
part of '../talky_api_client.dart';

extension MeetingsApi on TalkyApiClient {
  Future<List<dynamic>> getMeetings() async {
    final data = await _handleRequest(
      () => _client.get(Uri.parse('${TalkyApiClient.baseUrl}/meetings'), headers: _headers),
    );
    return data is List ? data : [];
  }

  /// Crée une réunion — backend attend: objet, start_time, room, duree, type_media
  Future<Map<String, dynamic>> createMeeting({
    required String objet,
    required String startTime, // ISO8601 ex: "2026-05-03T14:00:00"
    required String room,
    int duree = 60,
    int typeMedia = 0,
  }) async {
    final data = await _handleRequest(
      () => _client.post(
        Uri.parse('${TalkyApiClient.baseUrl}/meetings'),
        headers: _headers,
        body: jsonEncode({
          'objet': objet,
          'start_time': startTime,
          'room': room,
          'duree': duree,
          'type_media': typeMedia,
        }),
      ),
    );
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getMeeting(int idMeeting) async {
    final data = await _handleRequest(
      () => _client.get(Uri.parse('${TalkyApiClient.baseUrl}/meetings/$idMeeting'), headers: _headers),
    );
    return data as Map<String, dynamic>;
  }

  // `getMeetingByRoom` a été retirée avec `MeetingService.joinByRoom` : aucun
  // écran n'offre d'entrer par code de salon, la fonctionnalité n'existe pas
  // côté produit. La route serveur reste en place, désormais réservée aux
  // participants — elle servira si un lien d'invitation voit le jour, et la
  // retirer casserait un client déjà installé.

  Future<void> joinMeetingHttp(int idMeeting) async {
    await _handleRequest(
      () => _client.post(Uri.parse('${TalkyApiClient.baseUrl}/meetings/$idMeeting/join'), headers: _headers),
    );
  }

  Future<void> leaveMeetingHttp(int idMeeting) async {
    await _handleRequest(
      () => _client.post(Uri.parse('${TalkyApiClient.baseUrl}/meetings/$idMeeting/leave'), headers: _headers),
    );
  }

  Future<void> deleteMeeting(int idMeeting) async {
    await _handleRequest(
      () => _client.delete(Uri.parse('${TalkyApiClient.baseUrl}/meetings/$idMeeting'), headers: _headers),
    );
  }

  // `updateMeeting` a été retirée : aucun appelant, et elle envoyait un
  // `type_media` que le contrôleur n'a jamais traité — un champ ignoré en
  // silence, qui aurait répondu 200 sans rien changer. Il n'existe pas d'écran
  // d'édition de réunion ; le seul besoin réel est ci-dessous, et il est ciblé.

  /// Repli HTTP de « terminer pour tout le monde ».
  ///
  /// Le serveur, en voyant
  /// `isEnd` passer à 1, solde les participants et diffuse `meeting:ended`
  /// exactement comme le chemin socket.
  Future<void> updateMeetingEnd(int idMeeting) async {
    await _handleRequest(
      () => _client.put(
        Uri.parse('${TalkyApiClient.baseUrl}/meetings/$idMeeting'),
        headers: _headers,
        body: jsonEncode({'isEnd': 1}),
      ),
    );
  }

  Future<void> inviteParticipants(int idMeeting, List<int> participantIds) async {
    await _handleRequest(
      () => _client.post(
        Uri.parse('${TalkyApiClient.baseUrl}/meetings/$idMeeting/invite'),
        headers: _headers,
        body: jsonEncode({'participant_ids': participantIds}),
      ),
    );
  }
}
