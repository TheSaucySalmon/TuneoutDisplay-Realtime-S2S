// Verifies the edit-mode entry gesture geometry/arming logic. The full gesture
// (press -> swipe up -> hold 2s) and its feel must be confirmed on the Pi (no GL
// on the dev host), but the pure decision functions are verified here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_display/main.dart';

void main() {
  const size = Size(1920, 1080);

  group('editHandleRect', () {
    final r = editHandleRect(size);
    test('is a small centered strip at the very bottom', () {
      expect(r.width, size.width * 0.30); // 30% wide
      expect(r.height, 64);
      expect(r.bottom, size.height); // flush to bottom edge
      expect(r.center.dx, size.width / 2); // horizontally centered
    });
    test('contains a press at bottom-center', () {
      expect(r.contains(const Offset(960, 1050)), isTrue);
    });
    test('rejects presses near the bottom edges', () {
      expect(r.contains(const Offset(100, 1050)), isFalse); // far left
      expect(r.contains(const Offset(1820, 1050)), isFalse); // far right
    });
    test('rejects presses higher up the screen', () {
      expect(r.contains(const Offset(960, 500)), isFalse);
    });
  });

  group('editSwipeArmed', () {
    const start = Offset(960, 1050);
    test('arms on a clear upward swipe', () {
      expect(editSwipeArmed(start, const Offset(960, 1000)), isTrue); // up 50
    });
    test('does not arm on a small upward nudge', () {
      expect(editSwipeArmed(start, const Offset(960, 1030)), isFalse); // up 20
    });
    test('does not arm on a mostly-sideways drag', () {
      // up 50 but dx 90 -> sideways dominates
      expect(editSwipeArmed(start, const Offset(1050, 1000)), isFalse);
    });
    test('does not arm on a downward drag', () {
      expect(editSwipeArmed(start, const Offset(960, 1080)), isFalse);
    });
  });
}
