import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/incoming_presentation.dart';

void main() {
  group('decideIncomingPresentation', () {
    test('FG signal → showFlutterIncoming', () {
      expect(
        decideIncomingPresentation(
          callId: 'c1',
          appForeground: true,
          currentOwner: IncomingPresentationOwner.none,
          currentOwnerCallId: null,
          isAutoAnsweringFromPush: false,
          isTerminal: false,
          intent: IncomingPresentationIntent.signal,
        ),
        IncomingPresentationAction.showFlutterIncoming,
      );
    });

    test('BG signal → showNativeCallKit', () {
      expect(
        decideIncomingPresentation(
          callId: 'c1',
          appForeground: false,
          currentOwner: IncomingPresentationOwner.none,
          currentOwnerCallId: null,
          isAutoAnsweringFromPush: false,
          isTerminal: false,
          intent: IncomingPresentationIntent.signal,
        ),
        IncomingPresentationAction.showNativeCallKit,
      );
    });

    // `isCallKitActive` avait une valeur par défaut et **aucun appelant de
    // production** : rien ne le renseignait. C'est pourtant le seul moyen de
    // savoir que la notification est déjà posée — sur Android V2, elle l'est
    // par le Kotlin, sans que Dart en sache rien.
    test('CallKit affiche déjà cet entrant → mergeOnly, pas un second affichage',
        () {
      expect(
        decideIncomingPresentation(
          callId: 'c1',
          appForeground: false,
          currentOwner: IncomingPresentationOwner.none,
          currentOwnerCallId: null,
          isAutoAnsweringFromPush: false,
          isTerminal: false,
          intent: IncomingPresentationIntent.signal,
          isCallKitActive: true,
        ),
        IncomingPresentationAction.mergeOnly,
      );
    });

    test('démarrage à froid derrière un push → CallKit garde la main', () {
      // `appForeground` est faux depuis que l'état de cycle de vie inconnu
      // n'est plus pris pour un premier plan. Avec l'entrée CallKit déjà là,
      // rien de neuf ne doit être présenté.
      expect(
        decideIncomingPresentation(
          callId: 'c1',
          appForeground: false,
          currentOwner: IncomingPresentationOwner.none,
          currentOwnerCallId: null,
          isAutoAnsweringFromPush: false,
          isTerminal: false,
          intent: IncomingPresentationIntent.prepareFromCallKit,
          isCallKitActive: true,
        ),
        IncomingPresentationAction.mergeOnly,
      );
    });

    test('premier plan : Flutter reprend même si CallKit affiche', () {
      // Tap sur la notification, application déjà ouverte : c'est l'écran
      // Flutter qui présente, et l'entrée CallKit sera retirée sans refus.
      expect(
        decideIncomingPresentation(
          callId: 'c1',
          appForeground: true,
          currentOwner: IncomingPresentationOwner.none,
          currentOwnerCallId: null,
          isAutoAnsweringFromPush: false,
          isTerminal: false,
          intent: IncomingPresentationIntent.prepareFromCallKit,
          isCallKitActive: true,
        ),
        IncomingPresentationAction.showFlutterIncoming,
      );
    });

    test('même callId déjà owner → mergeOnly', () {
      expect(
        decideIncomingPresentation(
          callId: 'c1',
          appForeground: true,
          currentOwner: IncomingPresentationOwner.nativeCallKit,
          currentOwnerCallId: 'c1',
          isAutoAnsweringFromPush: false,
          isTerminal: false,
          intent: IncomingPresentationIntent.signal,
        ),
        IncomingPresentationAction.mergeOnly,
      );
    });

    test('autre callId actif → ignore', () {
      expect(
        decideIncomingPresentation(
          callId: 'c2',
          appForeground: true,
          currentOwner: IncomingPresentationOwner.flutterScreen,
          currentOwnerCallId: 'c1',
          isAutoAnsweringFromPush: false,
          isTerminal: false,
          intent: IncomingPresentationIntent.signal,
        ),
        IncomingPresentationAction.ignore,
      );
    });

    test('terminal → ignore', () {
      expect(
        decideIncomingPresentation(
          callId: 'c1',
          appForeground: true,
          currentOwner: IncomingPresentationOwner.none,
          currentOwnerCallId: null,
          isAutoAnsweringFromPush: false,
          isTerminal: true,
          intent: IncomingPresentationIntent.signal,
        ),
        IncomingPresentationAction.ignore,
      );
    });

    test('handoff intents', () {
      expect(
        decideIncomingPresentation(
          callId: 'c1',
          appForeground: false,
          currentOwner: IncomingPresentationOwner.flutterScreen,
          currentOwnerCallId: 'c1',
          isAutoAnsweringFromPush: false,
          isTerminal: false,
          intent: IncomingPresentationIntent.handoffToNative,
        ),
        IncomingPresentationAction.handoffToNative,
      );
      expect(
        decideIncomingPresentation(
          callId: 'c1',
          appForeground: true,
          currentOwner: IncomingPresentationOwner.nativeCallKit,
          currentOwnerCallId: 'c1',
          isAutoAnsweringFromPush: false,
          isTerminal: false,
          intent: IncomingPresentationIntent.handoffToFlutter,
        ),
        IncomingPresentationAction.handoffToFlutter,
      );
    });
  });

  group('claimIncomingPresentation', () {
    test('idempotent même owner', () {
      const current = IncomingPresentationState(
        owner: IncomingPresentationOwner.flutterScreen,
        callId: 'c1',
      );
      final r = claimIncomingPresentation(
        current: current,
        callId: 'c1',
        owner: IncomingPresentationOwner.flutterScreen,
        explicitHandoff: false,
        isTerminal: false,
      );
      expect(r.changed, isFalse);
      expect(r.ignored, isFalse);
      expect(r.state.owner, IncomingPresentationOwner.flutterScreen);
    });

    test('transition sans handoff → ignore', () {
      const current = IncomingPresentationState(
        owner: IncomingPresentationOwner.flutterScreen,
        callId: 'c1',
      );
      final r = claimIncomingPresentation(
        current: current,
        callId: 'c1',
        owner: IncomingPresentationOwner.nativeCallKit,
        explicitHandoff: false,
        isTerminal: false,
      );
      expect(r.ignored, isTrue);
      expect(r.state.owner, IncomingPresentationOwner.flutterScreen);
    });

    test('handoff explicite → change owner', () {
      const current = IncomingPresentationState(
        owner: IncomingPresentationOwner.flutterScreen,
        callId: 'c1',
      );
      final r = claimIncomingPresentation(
        current: current,
        callId: 'c1',
        owner: IncomingPresentationOwner.nativeCallKit,
        explicitHandoff: true,
        isTerminal: false,
      );
      expect(r.changed, isTrue);
      expect(r.state.owner, IncomingPresentationOwner.nativeCallKit);
      expect(r.state.callId, 'c1');
    });

    test('autre callId → ignore', () {
      const current = IncomingPresentationState(
        owner: IncomingPresentationOwner.nativeCallKit,
        callId: 'old',
      );
      final r = claimIncomingPresentation(
        current: current,
        callId: 'new',
        owner: IncomingPresentationOwner.flutterScreen,
        explicitHandoff: true,
        isTerminal: false,
      );
      expect(r.ignored, isTrue);
      expect(r.state.callId, 'old');
    });

    test('terminal → ignore', () {
      final r = claimIncomingPresentation(
        current: IncomingPresentationState.empty,
        callId: 'c1',
        owner: IncomingPresentationOwner.flutterScreen,
        explicitHandoff: false,
        isTerminal: true,
      );
      expect(r.ignored, isTrue);
      expect(r.state.isActive, isFalse);
    });
  });

  group('clearIncomingPresentationState', () {
    test('clear ciblé ne touche pas un autre callId', () {
      const current = IncomingPresentationState(
        owner: IncomingPresentationOwner.nativeCallKit,
        callId: 'c1',
      );
      final next = clearIncomingPresentationState(
        current: current,
        callId: 'late-push',
      );
      expect(next.callId, 'c1');
      expect(next.owner, IncomingPresentationOwner.nativeCallKit);
    });

    test('clear match → empty', () {
      const current = IncomingPresentationState(
        owner: IncomingPresentationOwner.flutterScreen,
        callId: 'c1',
      );
      final next = clearIncomingPresentationState(
        current: current,
        callId: 'c1',
      );
      expect(next.isActive, isFalse);
    });

    test('clear sans callId → empty', () {
      const current = IncomingPresentationState(
        owner: IncomingPresentationOwner.flutterScreen,
        callId: 'c1',
      );
      expect(
        clearIncomingPresentationState(current: current).isActive,
        isFalse,
      );
    });
  });

  group('evaluateShouldShowFlutterIncomingUi', () {
    test('Flutter owner FG → true', () {
      expect(
        evaluateShouldShowFlutterIncomingUi(
          statusIsIncoming: true,
          isAutoAnsweringFromPush: false,
          appForeground: true,
          owner: IncomingPresentationOwner.flutterScreen,
          ownerCallId: 'c1',
          currentCallId: 'c1',
        ),
        isTrue,
      );
    });

    test('CallKit owner → false même si incoming', () {
      expect(
        evaluateShouldShowFlutterIncomingUi(
          statusIsIncoming: true,
          isAutoAnsweringFromPush: false,
          appForeground: true,
          owner: IncomingPresentationOwner.nativeCallKit,
          ownerCallId: 'c1',
          currentCallId: 'c1',
        ),
        isFalse,
      );
    });

    test('auto-answer → false', () {
      expect(
        evaluateShouldShowFlutterIncomingUi(
          statusIsIncoming: true,
          isAutoAnsweringFromPush: true,
          appForeground: true,
          owner: IncomingPresentationOwner.flutterScreen,
          ownerCallId: 'c1',
          currentCallId: 'c1',
        ),
        isFalse,
      );
    });

    test('ownerCallId ≠ currentCallId → false', () {
      expect(
        evaluateShouldShowFlutterIncomingUi(
          statusIsIncoming: true,
          isAutoAnsweringFromPush: false,
          appForeground: true,
          owner: IncomingPresentationOwner.flutterScreen,
          ownerCallId: 'old',
          currentCallId: 'new',
        ),
        isFalse,
      );
    });
  });

  // Checklist manuelle (hors CI) :
  // - FG socket seul → IncomingCallScreen + ringtone, pas CallKit
  // - BG FCM CallKit + Socket même callId → une seule UI CallKit
  // - FG sonnerie → lockscreen → CallKit showIncoming forcé, pas reject_call
  // - Resume FG → markProgrammaticDismiss + IncomingCallScreen, pas reject
  // - Accept CallKit → OngoingCallScreen seulement
}
