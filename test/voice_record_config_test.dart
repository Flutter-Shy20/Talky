import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:talky_flutter/core/services/voice_record_config.dart';

void main() {
  test('la voix est enregistrée en AAC mono à 32 kbit/s, 22,05 kHz', () {
    expect(kVoiceRecordConfig.encoder, AudioEncoder.aacLc);
    expect(kVoiceRecordConfig.bitRate, 32000);
    expect(kVoiceRecordConfig.numChannels, 1);
    expect(kVoiceRecordConfig.sampleRate, 22050);
  });

  test('une minute de voix pèse ≈ 240 Ko', () {
    final octetsParMinute = kVoiceRecordConfig.bitRate * 60 ~/ 8;
    expect(octetsParMinute, 240000);
  });
}
