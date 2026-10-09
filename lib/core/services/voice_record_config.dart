import 'package:record/record.dart';

/// Réglages d'enregistrement de la voix, pour tous les enregistreurs de l'app :
/// messages vocaux, statuts vocaux, réponses vocales aux statuts, messages
/// laissés sur le répondeur, annonce du répondeur.
///
/// AAC-LC mono à 32 kbit/s et 22,05 kHz : ≈ 240 Ko par minute, contre ≈ 1 Mo
/// avec les réglages par défaut du plugin (128 kbit/s, stéréo, 44,1 kHz). Le
/// micro d'un téléphone capte la voix en mono, et 22,05 kHz restituent les
/// fréquences jusqu'à ≈ 11 kHz, bien au-delà de ce qu'exige une voix nette.
///
/// Le format reste l'AAC, que tous les téléphones et toutes les versions de
/// l'app savent lire. Opus serait plus léger, mais `record` ne l'encode pas
/// sur iOS, et iOS ne lit pas l'Ogg dans lequel Android l'écrit.
const RecordConfig kVoiceRecordConfig = RecordConfig(
  encoder: AudioEncoder.aacLc,
  bitRate: 32000,
  numChannels: 1,
  sampleRate: 22050,
);
