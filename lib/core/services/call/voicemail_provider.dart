import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../../../talky_api_client.dart';
import '../../../talky_models.dart';
import 'voicemail_rules.dart';

/// État du répondeur, partagé par le bandeau, l'écran de réglage et la feuille
/// d'activation rapide.
///
/// Il ne calcule aucun créneau. Savoir si le répondeur intercepte demande de
/// résoudre un fuseau par cascade — réglage de l'appareil, puis pays du compte,
/// puis serveur — et une seconde implémentation de ce calcul finirait par
/// diverger de celle du serveur. Le serveur répond donc `active` et
/// `activeUntil`, et ce service se contente de les afficher et d'armer un
/// minuteur sur l'échéance.
///
/// Trois sources le tiennent à jour :
///  - chaque écriture, dont la réponse fait foi ;
///  - l'événement `voicemail_schedule_updated`, émis par le serveur à toutes
///    les sockets du compte — le réglage est par compte, le bandeau est par
///    appareil, et sans lui le second téléphone garderait un bandeau périmé ;
///  - le retour au premier plan, filet pour les événements manqués hors ligne.
class VoicemailProvider extends ChangeNotifier with WidgetsBindingObserver {
  final TalkyApiClient _api;

  VoicemailSchedule? _schedule;
  bool _loading = false;
  bool _saving = false;
  Timer? _echeance;
  bool _fuseauPousse = false;

  VoicemailProvider({required TalkyApiClient api}) : _api = api {
    WidgetsBinding.instance.addObserver(this);
    _api.onSocketEvent(SocketEvents.voicemailScheduleUpdated, _surEvenement);
  }

  VoicemailSchedule? get schedule => _schedule;
  bool get isLoading => _loading;
  bool get isSaving => _saving;

  /// Le bandeau doit-il s'afficher maintenant ?
  bool get isActive => shouldShowBanner(_schedule, now: DateTime.now().toUtc());

  /// `HH:MM` local, ou `null` si le créneau n'a pas d'échéance calculable.
  String? get deadline => deadlineLabel(_schedule?.activeUntil);

  @override
  void dispose() {
    _echeance?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  void _surEvenement(dynamic data) {
    if (data is! Map) return;
    try {
      _appliquer(VoicemailSchedule.fromJson(Map<String, dynamic>.from(data)));
    } catch (e) {
      debugPrint('[VoicemailProvider] événement illisible: $e');
    }
  }

  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    notifyListeners();
    try {
      _appliquer(await _api.getVoicemailSchedule());
      unawaited(_pousserLeFuseau());
    } catch (e) {
      // Un échec de lecture ne doit rien changer à l'écran : on garde le
      // dernier état connu plutôt que d'effacer un bandeau qui décrit peut-être
      // encore la réalité.
      debugPrint('[VoicemailProvider] lecture échouée: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Écriture partielle. La réponse du serveur fait foi — y compris pour
  /// `active` et `activeUntil`, qu'il est seul à savoir calculer.
  Future<VoicemailSchedule> patch(Map<String, dynamic> patch) async {
    _saving = true;
    notifyListeners();
    try {
      final next = await _api.patchVoicemailSchedule(patch);
      _appliquer(next);
      return next;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  /// Arme le répondeur jusqu'à une échéance calculée sur l'appareil, en heure
  /// murale locale, puis convertie en UTC.
  Future<VoicemailSchedule> activateUntil(DateTime deadlineLocal) =>
      patch(activatePatch(deadlineLocal));

  /// Éteint tout d'un geste : l'activation ponctuelle ET la règle récurrente.
  /// N'effacer que la première laisserait le bandeau en place si un créneau
  /// récurrent est en cours, et le bouton paraîtrait cassé.
  Future<VoicemailSchedule> disable() => patch(disablePatch());

  void _appliquer(VoicemailSchedule next) {
    _schedule = next;
    _armerEcheance(next);
    notifyListeners();
  }

  /// Un minuteur unique, visant l'échéance elle-même.
  ///
  /// Pas de battement régulier : un bandeau qui doit disparaître à 17 h n'a
  /// aucune raison de réveiller le téléphone toutes les trente secondes
  /// jusque-là. À l'échéance, on ne rappelle pas le serveur non plus — on
  /// notifie, et `shouldShowBanner` constate que la date est passée.
  void _armerEcheance(VoicemailSchedule next) {
    _echeance?.cancel();
    final delai = bannerRefreshDelay(next, now: DateTime.now().toUtc());
    if (delai == null) return;
    // Au-delà d'une journée, on laisse le retour au premier plan faire le
    // travail : un Timer très long ne survit pas au sommeil du système.
    if (delai > const Duration(days: 1)) return;
    _echeance = Timer(delai, () {
      _echeance = null;
      notifyListeners();
    });
  }

  /// Pousse le fuseau IANA de l'appareil, une fois par session et seulement
  /// s'il diffère de ce que le compte porte déjà.
  ///
  /// C'est le premier étage de la cascade : sans lui, le créneau récurrent est
  /// évalué dans le fuseau du PAYS du compte — correct pour qui ne voyage pas,
  /// faux d'une heure ou plus pour qui voyage. L'échec est silencieux : ce
  /// réglage améliore la précision, il ne conditionne rien.
  Future<void> _pousserLeFuseau() async {
    if (_fuseauPousse) return;
    _fuseauPousse = true;
    try {
      final nom = await FlutterTimezone.getLocalTimezone();
      if (nom.isEmpty || nom == _schedule?.timezone) return;
      await patch({'timezone': nom});
    } catch (e) {
      debugPrint('[VoicemailProvider] fuseau non poussé: $e');
    }
  }
}
