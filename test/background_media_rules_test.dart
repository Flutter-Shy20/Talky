import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/background_media_rules.dart';

void main() {
  bool shouldPause({
    bool isVideo = true,
    bool appBackgrounded = true,
    bool systemPipActive = false,
    bool cameraAllowedInBackground = false,
  }) =>
      localVideoShouldPause(
        isVideo: isVideo,
        appBackgrounded: appBackgrounded,
        systemPipActive: systemPipActive,
        cameraAllowedInBackground: cameraAllowedInBackground,
      );

  test('au premier plan, jamais', () {
    expect(shouldPause(appBackgrounded: false), isFalse);
  });

  test('un appel audio n\'a pas de caméra à couper', () {
    expect(shouldPause(isVideo: false), isFalse);
  });

  test('en arrière-plan sans droit de capture, on coupe', () {
    expect(
      shouldPause(),
      isTrue,
      reason: 'iOS suspend la capture de lui-même sans l\'autorisation : '
          'autant relâcher la piste proprement',
    );
  });

  test('en Picture-in-Picture, on garde la caméra', () {
    expect(
      shouldPause(systemPipActive: true),
      isFalse,
      reason: 'en PiP Android l\'activité est en pause TOUT EN restant '
          'visible : couper là serait couper au moment précis où le PiP '
          's\'ouvre',
    );
  });

  test('le PiP l\'emporte même sans droit de capture en arrière-plan', () {
    expect(
      shouldPause(systemPipActive: true, cameraAllowedInBackground: false),
      isFalse,
    );
  });

  test('un service de premier plan caméra suffit à continuer', () {
    expect(shouldPause(cameraAllowedInBackground: true), isFalse);
  });
}
