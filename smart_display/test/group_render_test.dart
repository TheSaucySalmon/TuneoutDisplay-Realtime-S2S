// Headless verification of group sub-button + header rendering/dispatch. The
// assembled _GroupCard (which needs the LiquidGlass scope stack) is verified on
// the Pi; here we render the pieces in isolation.
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_display/main.dart';

void main() {
  testWidgets('button sub-button shows its name, no exceptions', (tester) async {
    await tester.pumpWidget(buildSubButtonForTest(
        SubButton(id: 'a', entityId: 'switch.demo', name: 'White Noise')));
    await tester.pump();
    expect(find.text('White Noise'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slider sub-button (light) shows a % value', (tester) async {
    await tester.pumpWidget(buildSubButtonForTest(SubButton(
        id: 'b',
        type: 'slider',
        entityId: 'light.demo_light',
        name: 'Brightness')));
    await tester.pump();
    expect(find.textContaining('%'), findsOneWidget); // "Brightness · 70%"
    expect(tester.takeException(), isNull);
  });

  testWidgets('select sub-button shows the current option + opens a picker',
      (tester) async {
    await tester.pumpWidget(buildSubButtonForTest(SubButton(
        id: 'c', type: 'select', entityId: 'select.demo_select', name: 'Mode')));
    await tester.pump();
    expect(find.textContaining('Cool'), findsOneWidget); // current option
    await tester.tap(find.textContaining('Cool')); // tap the pill
    await tester.pumpAndSettle();
    expect(find.text('Warm'), findsWidgets); // option in the picker
    expect(tester.takeException(), isNull);
  });

  testWidgets('group header shows its name', (tester) async {
    await tester.pumpWidget(buildGroupHeaderForTest(CardSpec(
        id: 'g',
        kind: CardKind.group,
        col: 0,
        row: 0,
        w: 2,
        h: 2,
        entityId: 'light.demo_light',
        name: "Jake's Room Lights")));
    await tester.pump();
    expect(find.text("Jake's Room Lights"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
