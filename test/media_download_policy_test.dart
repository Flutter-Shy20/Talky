import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talky_flutter/core/services/connectivity_service.dart';
import 'package:talky_flutter/core/services/media_download_preferences.dart';

/// Réseau simulé : la décision d'auto-téléchargement dépend de son type, pas
/// de sa disponibilité.
class _FauxReseau extends ConnectivityService {
  _FauxReseau(this.nonMesure);
  final bool nonMesure;
  bool consulte = false;

  @override
  Future<bool> get currentIsUnmetered async {
    consulte = true;
    return nonMesure;
  }
}

/// Réseau dont l'interrogation échoue (permission refusée, plateforme muette).
class _ReseauEnPanne extends ConnectivityService {
  @override
  Future<bool> get currentIsUnmetered async => throw Exception('indéterminable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Repart d'un état de préférences connu à chaque cas.
  Future<MediaDownloadPreferences> prefsAvec({
    bool? autoDownload,
    bool? wifiOnly,
    bool? dataSaver,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (autoDownload != null) 'auto_download_media': autoDownload,
      if (wifiOnly != null) 'media_wifi_only': wifiOnly,
      if (dataSaver != null) 'media_data_saver': dataSaver,
    });
    final p = MediaDownloadPreferences();
    // `preload` mémorise son premier chargement : on passe par `load`, qui
    // relit et réaligne l'instance liée.
    await p.load();
    if (autoDownload != null) await p.setAutoDownload(autoDownload);
    if (wifiOnly != null) await p.setWifiOnly(wifiOnly);
    if (dataSaver != null) await p.setDataSaver(dataSaver);
    return p;
  }

  group('valeurs par défaut', () {
    test('auto-téléchargement actif, restreint au Wi-Fi', () {
      // Les deux vont ensemble : activer le téléchargement automatique n'est
      // défendable que parce qu'il ne consomme pas les données mobiles.
      expect(kAutoDownloadParDefaut, isTrue);
      expect(kWifiOnlyParDefaut, isTrue);
    });
  });

  group('shouldAutoDownloadNow', () {
    test('préférence coupée → jamais, sans même regarder le réseau', () async {
      await prefsAvec(autoDownload: false, wifiOnly: false);
      final reseau = _FauxReseau(true);
      expect(
        await MediaDownloadPreferences.shouldAutoDownloadNow(connectivity: reseau),
        isFalse,
      );
      expect(reseau.consulte, isFalse, reason: 'inutile de sonder le réseau');
    });

    test('sans restriction → télécharge quel que soit le réseau', () async {
      await prefsAvec(autoDownload: true, wifiOnly: false, dataSaver: false);
      expect(
        await MediaDownloadPreferences.shouldAutoDownloadNow(
            connectivity: _FauxReseau(false)),
        isTrue,
      );
    });

    test('« Wi-Fi uniquement » : télécharge sur Wi-Fi, s\'abstient en mobile', () async {
      await prefsAvec(autoDownload: true, wifiOnly: true, dataSaver: false);
      expect(
        await MediaDownloadPreferences.shouldAutoDownloadNow(
            connectivity: _FauxReseau(true)),
        isTrue,
        reason: 'Wi-Fi : rien ne se paie au volume',
      );
      expect(
        await MediaDownloadPreferences.shouldAutoDownloadNow(
            connectivity: _FauxReseau(false)),
        isFalse,
        reason: 'données mobiles : ne pas dépenser le forfait sans demande',
      );
    });

    test('l\'économiseur de données restreint comme « Wi-Fi uniquement »', () async {
      // Les deux réglages expriment la même intention ; l'un ou l'autre suffit.
      await prefsAvec(autoDownload: true, wifiOnly: false, dataSaver: true);
      expect(
        await MediaDownloadPreferences.shouldAutoDownloadNow(
            connectivity: _FauxReseau(false)),
        isFalse,
      );
    });

    test('réseau indéterminable → abstention', () async {
      // Une vignette manquante se rattrape d'un appui ; du forfait consommé
      // par erreur, non. En cas de doute on ne télécharge pas.
      await prefsAvec(autoDownload: true, wifiOnly: true);
      expect(
        await MediaDownloadPreferences.shouldAutoDownloadNow(
            connectivity: _ReseauEnPanne()),
        isFalse,
      );
    });
  });
}
