// Headless verification of the per-domain more-info controls.
//
// The Flutter GUI can't render on the dev host (no hardware GL), so these widget
// tests render the real `_MoreInfoSheet` for representative demo entities and
// assert each domain's controls appear without exceptions/overflow. Live visual
// confirmation happens on the Pi after deploy.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_display/main.dart';

void main() {
  testWidgets('light → brightness + color-temp sliders + color swatches',
      (tester) async {
    await tester.pumpWidget(buildDemoMoreInfoSheet('light.demo_light'));
    await tester.pump();
    expect(find.text('Demo Light'), findsOneWidget);
    // demo_light supports color_temp + hs → two sliders (brightness, temp).
    expect(find.byType(Slider), findsNWidgets(2));
    expect(find.text('Color'), findsOneWidget); // swatch section header
    expect(tester.takeException(), isNull);
  });

  testWidgets('media_player → source + sound-mode selectors', (tester) async {
    await tester.pumpWidget(buildDemoMoreInfoSheet('media_player.demo_player'));
    await tester.pump();
    expect(find.text('Source'), findsOneWidget);
    expect(find.text('Spotify'), findsWidgets); // a source chip
    expect(find.text('Sound mode'), findsOneWidget);
    expect(find.text('Surround'), findsOneWidget); // a sound-mode chip
    expect(tester.takeException(), isNull);
  });

  testWidgets('valve → open/stop/close + position slider', (tester) async {
    await tester.pumpWidget(buildDemoMoreInfoSheet('valve.demo_valve'));
    await tester.pump();
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget); // position (reports_position)
    expect(tester.takeException(), isNull);
  });

  testWidgets('water_heater → temp steppers, operation modes, away pill',
      (tester) async {
    await tester.pumpWidget(buildDemoMoreInfoSheet('water_heater.demo_tank'));
    await tester.pump();
    expect(find.text('−'), findsOneWidget);
    expect(find.text('+'), findsOneWidget);
    expect(find.text('electric'), findsOneWidget); // an operation_list chip
    expect(find.text('Away'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('humidifier → target slider + mode chips + on pill',
      (tester) async {
    await tester.pumpWidget(buildDemoMoreInfoSheet('humidifier.demo_humidifier'));
    await tester.pump();
    expect(find.byType(Slider), findsOneWidget); // target humidity
    expect(find.text('baby'), findsOneWidget); // an available_modes chip
    expect(find.text('On'), findsOneWidget); // header toggle pill
    expect(tester.takeException(), isNull);
  });

  testWidgets('date → button opens a date picker', (tester) async {
    await tester.pumpWidget(buildDemoMoreInfoSheet('date.demo_date'));
    await tester.pump();
    expect(find.text('Set date'), findsOneWidget);
    await tester.tap(find.text('Set date'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('time → button opens a time picker', (tester) async {
    await tester.pumpWidget(buildDemoMoreInfoSheet('time.demo_time'));
    await tester.pump();
    expect(find.text('Set time'), findsOneWidget);
    await tester.tap(find.text('Set time'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('datetime → button renders cleanly', (tester) async {
    await tester.pumpWidget(buildDemoMoreInfoSheet('datetime.demo_datetime'));
    await tester.pump();
    expect(find.text('Set date & time'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('alarm → arm buttons per supported_features bits', (tester) async {
    // demo_alarm features = 47 → Home|Away|Night|Trigger|Vacation (no Custom).
    await tester.pumpWidget(buildDemoMoreInfoSheet('alarm_control_panel.demo_alarm'));
    await tester.pump();
    expect(find.text('Arm Home'), findsOneWidget);
    expect(find.text('Arm Away'), findsOneWidget);
    expect(find.text('Arm Night'), findsOneWidget);
    expect(find.text('Arm Vacation'), findsOneWidget);
    expect(find.text('Custom Bypass'), findsNothing); // bit 16 not set
    expect(find.text('Disarm'), findsNothing); // already disarmed
    expect(tester.takeException(), isNull);
  });

  testWidgets('vacuum → action buttons + fan-speed chips per bits',
      (tester) async {
    await tester.pumpWidget(buildDemoMoreInfoSheet('vacuum.demo_vacuum'));
    await tester.pump();
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Dock'), findsOneWidget);
    expect(find.text('Spot'), findsOneWidget);
    expect(find.text('Fan speed'), findsOneWidget);
    expect(find.text('turbo'), findsOneWidget); // a fan_speed_list chip
    expect(tester.takeException(), isNull);
  });
}
