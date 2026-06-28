// Pure-logic verification of the press-hold drag-to-adjust slider: which entities
// are adjustable, the value/service mapping, and the fill color. The gesture and
// fill rendering are verified on the Pi (no GL on the dev host).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_display/main.dart';

void main() {
  test('CardSpec.sliderReadout round-trips and defaults to true', () {
    final c = CardSpec(
        id: 'a', kind: CardKind.entity, col: 0, row: 0, w: 1, h: 1,
        sliderReadout: false);
    expect(CardSpec.fromJson(c.toJson()).sliderReadout, isFalse);
    final legacy = c.toJson()..remove('sliderReadout');
    expect(CardSpec.fromJson(legacy).sliderReadout, isTrue); // default
  });

  testWidgets('adjustable card fills its slot (regression: width-2 collapse)',
      (tester) async {
    late BoxConstraints captured;
    await tester.pumpWidget(buildAdjustableCardForTest(
      child: LayoutBuilder(builder: (ctx, c) {
        captured = c;
        return const SizedBox.expand();
      }),
    ));
    await tester.pump();
    // The card must be forced to fill its 200x100 slot (StackFit.expand), not
    // shrink to its content.
    expect(captured.maxWidth, 200);
    expect(captured.maxHeight, 100);
    expect(captured.minWidth, 200,
        reason: 'card child must get tight constraints, not loose');
    expect(captured.minHeight, 100);
  });

  group('cardAdjustment', () {
    test('light brightness -> turn_on/brightness_pct', () {
      final a = cardAdjustment('light', {
        'brightness': 128,
        'supported_color_modes': ['brightness'],
      })!;
      expect(a.value, closeTo(50.2, 0.5));
      expect(a.service, 'turn_on');
      expect(a.data(50), {'brightness_pct': 50});
    });

    test('on/off-only light is not adjustable', () {
      expect(
          cardAdjustment('light', {
            'supported_color_modes': ['onoff']
          }),
          isNull);
    });

    test('light that is off is still adjustable (value 0)', () {
      final a = cardAdjustment('light', {
        'supported_color_modes': ['color_temp']
      })!;
      expect(a.value, 0);
    });

    test('media volume -> volume_set/volume_level', () {
      final a = cardAdjustment('media_player', {'volume_level': 0.4})!;
      expect(a.value, closeTo(40, 0.01));
      expect(a.service, 'volume_set');
      expect(a.data(50), {'volume_level': 0.5});
    });

    test('cover position -> set_cover_position/position', () {
      final a = cardAdjustment('cover', {'current_position': 70})!;
      expect(a.value, 70);
      expect(a.data(30), {'position': 30});
    });

    test('fan percentage -> set_percentage/percentage', () {
      final a = cardAdjustment('fan', {'percentage': 25})!;
      expect(a.value, 25);
      expect(a.data(80), {'percentage': 80});
    });

    test('non-adjustable domains return null', () {
      expect(cardAdjustment('switch', {'state': 'on'}), isNull);
      expect(cardAdjustment('sensor', {'state': '21'}), isNull);
      expect(cardAdjustment('media_player', const {}), isNull); // no volume
    });
  });

  group('sliderFillColor', () {
    const accent = Color(0xFF3366FF);
    test('light uses rgb_color when present', () {
      expect(sliderFillColor('light', {'rgb_color': [255, 180, 60]}, accent),
          const Color.fromARGB(255, 255, 180, 60));
    });
    test('light falls back to hs_color', () {
      // hue 120, sat 100 -> pure green
      expect(sliderFillColor('light', {'hs_color': [120, 100]}, accent),
          const Color(0xFF00FF00));
    });
    test('light with no color -> accent', () {
      expect(sliderFillColor('light', const {}, accent), accent);
    });
    test('non-light -> accent', () {
      expect(sliderFillColor('media_player', {'rgb_color': [1, 2, 3]}, accent),
          accent);
    });
  });
}
