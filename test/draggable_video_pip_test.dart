import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/widgets/calls/draggable_video_pip.dart';

void main() {
  const screenSize = Size(400, 800);
  const safeArea = EdgeInsets.only(top: 44, bottom: 34);

  PipLayoutBounds normalBounds() => computePipBounds(
        screenSize: screenSize,
        safeArea: safeArea,
        controlsVisible: true,
      );

  PipLayoutBounds immersiveBounds() => computePipBounds(
        screenSize: screenSize,
        safeArea: safeArea,
        controlsVisible: false,
      );

  group('defaultPipOffset', () {
    test('places PiP in the top-right corner', () {
      final bounds = normalBounds();
      final offset = defaultPipOffset(bounds);

      expect(offset.dx, bounds.maxX);
      expect(offset.dy, bounds.minY);
    });
  });

  group('pipChildKey', () {
    test('same widget kind keeps its key across rebuilds', () {
      // La clé valait identityHashCode(child) : l'enfant étant reconstruit à
      // chaque build, elle changeait à chaque image et l'AnimatedSwitcher
      // rejouait sa transition sans fin.
      const a = SizedBox(width: 1);
      const b = SizedBox(width: 2);

      expect(pipChildKey(a), pipChildKey(b));
    });

    test('changing the kind of child changes the key', () {
      expect(
        pipChildKey(const SizedBox()),
        isNot(pipChildKey(const Placeholder())),
        reason: 'passer de la vidéo à l\'avatar doit bien déclencher la '
            'transition',
      );
    });
  });

  group('clampPipOffset', () {
    test('keeps position inside normal bounds', () {
      final bounds = normalBounds();
      final clamped = clampPipOffset(const Offset(200, 200), bounds);

      expect(clamped.dx, greaterThanOrEqualTo(bounds.minX));
      expect(clamped.dx, lessThanOrEqualTo(bounds.maxX));
      expect(clamped.dy, greaterThanOrEqualTo(bounds.minY));
      expect(clamped.dy, lessThanOrEqualTo(bounds.maxY));
    });

    test('clamps overflow on the left and top', () {
      final bounds = normalBounds();
      final clamped = clampPipOffset(const Offset(-50, -50), bounds);

      expect(clamped.dx, bounds.minX);
      expect(clamped.dy, bounds.minY);
    });

    test('clamps overflow on the right and bottom', () {
      final bounds = normalBounds();
      final clamped = clampPipOffset(const Offset(999, 999), bounds);

      expect(clamped.dx, bounds.maxX);
      expect(clamped.dy, bounds.maxY);
    });
  });

  group('computePipBounds', () {
    test('immersive mode allows lower PiP placement than normal mode', () {
      final normal = normalBounds();
      final immersive = immersiveBounds();

      expect(immersive.maxY, greaterThan(normal.maxY));
      expect(immersive.minY, lessThan(normal.minY));
    });
  });

  group('reclampPipOffset', () {
    test('returns null when position is null', () {
      expect(reclampPipOffset(null, normalBounds()), isNull);
    });

    test('returns same offset when already inside bounds', () {
      final bounds = normalBounds();
      const position = Offset(100, 150);

      expect(reclampPipOffset(position, bounds), position);
    });

    test('re-clamps when returning from immersive to normal mode', () {
      final immersive = immersiveBounds();
      final normal = normalBounds();
      final lowPosition = Offset(immersive.minX, immersive.maxY);

      final reclamped = reclampPipOffset(lowPosition, normal);

      expect(reclamped, isNotNull);
      expect(reclamped!.dy, normal.maxY);
      expect(reclamped.dy, lessThan(lowPosition.dy));
    });
  });

  group('computeFloatingWindowBounds', () {
    PipLayoutBounds floating() => computeFloatingWindowBounds(
          screenSize: screenSize,
          safeArea: safeArea,
        );

    test('n\'est bornée que par les zones sûres', () {
      final bounds = floating();

      expect(bounds.minY, greaterThan(safeArea.top));
      expect(
        bounds.minY,
        lessThan(normalBounds().minY),
        reason: 'la fenêtre flotte au-dessus de n\'importe quel écran : elle '
            'n\'a ni barre d\'appel ni contrôles à contourner',
      );
    });

    test('laisse la fenêtre entièrement à l\'écran', () {
      final bounds = floating();

      expect(bounds.maxX + kFloatingWindowWidth, lessThan(screenSize.width));
      expect(
        bounds.maxY + kFloatingWindowHeight,
        lessThanOrEqualTo(screenSize.height - safeArea.bottom),
      );
    });

    test('reste utilisable : la zone de dépôt n\'est pas vide', () {
      final bounds = floating();

      expect(bounds.maxX, greaterThan(bounds.minX));
      expect(bounds.maxY, greaterThan(bounds.minY));
    });
  });
}
