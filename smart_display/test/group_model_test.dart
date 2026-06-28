// Model-level verification of the group card (Bubble-Card-style): SubButton +
// CardSpec.subButtons serialization, defaults, and enum-index stability.
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_display/main.dart';

void main() {
  test('CardKind indices are stable (group appended last)', () {
    // layout.json persists `kind` by index — existing kinds must not shift.
    expect(CardKind.weather.index, 0);
    expect(CardKind.camera.index, 1);
    expect(CardKind.calendar.index, 2);
    expect(CardKind.haStatus.index, 3);
    expect(CardKind.entity.index, 4);
    expect(CardKind.group.index, 5);
  });

  test('SubButton round-trips through json', () {
    final s = SubButton(
        id: 'b1',
        type: 'slider',
        entityId: 'light.x',
        name: 'Brightness',
        tap: 'more-info',
        min: 0,
        max: 100,
        step: 5);
    final r = SubButton.fromJson(s.toJson());
    expect(r.id, 'b1');
    expect(r.type, 'slider');
    expect(r.entityId, 'light.x');
    expect(r.name, 'Brightness');
    expect(r.tap, 'more-info');
    expect(r.min, 0);
    expect(r.max, 100);
    expect(r.step, 5);
  });

  test('SubButton defaults (button/toggle) when fields absent', () {
    final r = SubButton.fromJson({'id': 'x'});
    expect(r.type, 'button');
    expect(r.tap, 'toggle');
    expect(r.entityId, isNull);
  });

  test('CardSpec carries sub-buttons through json', () {
    final c = CardSpec(
      id: 'g',
      kind: CardKind.group,
      col: 0,
      row: 0,
      w: 2,
      h: 2,
      name: "Jake's Room Lights",
      subButtons: [
        SubButton(id: 'a', entityId: 'light.room1', name: "Jake's Room 1"),
        SubButton(id: 'b', type: 'slider', entityId: 'light.room1'),
      ],
    );
    final r = CardSpec.fromJson(c.toJson());
    expect(r.kind, CardKind.group);
    expect(r.name, "Jake's Room Lights");
    expect(r.subButtons.length, 2);
    expect(r.subButtons.first.entityId, 'light.room1');
    expect(r.subButtons[1].type, 'slider');
  });

  test('addGroup adds an empty group card on the active page', () {
    final l = AppLayout(
        [CardSpec(id: 'a', kind: CardKind.entity, col: 0, row: 0, w: 1, h: 1)],
        pageCount: 2)
      ..persist = false
      ..activePage = 1;
    final g = l.addGroup();
    expect(g.kind, CardKind.group);
    expect(g.page, 1);
    expect(g.subButtons, isEmpty);
    expect(l.cards.contains(g), isTrue);
  });

  test('legacy card json (no subButtons) → empty, mutable list', () {
    final legacy = CardSpec(id: 'e', kind: CardKind.entity, col: 0, row: 0, w: 1, h: 1)
        .toJson()
      ..remove('subButtons');
    final r = CardSpec.fromJson(legacy);
    expect(r.subButtons, isEmpty);
    r.subButtons.add(SubButton(id: 'z')); // must be growable
    expect(r.subButtons.length, 1);
  });
}
