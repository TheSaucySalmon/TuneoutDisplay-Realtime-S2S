// Model-level verification of the paging system: CardSpec.page round-trip,
// layout.json migration (legacy bare-array + new object form), and add/remove
// page logic. The PageView UI itself is verified visually on the Pi.
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_display/main.dart';

CardSpec _card(String id, {int page = 0}) => CardSpec(
    id: id, kind: CardKind.entity, entityId: 'light.$id',
    col: 0, row: 0, w: 1, h: 1, page: page);

void main() {
  test('CardSpec.page round-trips through json', () {
    final c = _card('a', page: 3);
    expect(CardSpec.fromJson(c.toJson()).page, 3);
  });

  test('CardSpec defaults to page 0 when absent (legacy json)', () {
    final j = _card('a').toJson()..remove('page');
    expect(CardSpec.fromJson(j).page, 0);
  });

  group('migration via fromDecoded', () {
    test('legacy bare array -> single page', () {
      final legacy = [_card('a').toJson(), _card('b').toJson()];
      final l = AppLayout.fromDecoded(legacy);
      expect(l.cards.length, 2);
      expect(l.pageCount, 1);
    });

    test('new object form preserves pageCount', () {
      final obj = {
        'pageCount': 3,
        'cards': [_card('a', page: 2).toJson()],
      };
      final l = AppLayout.fromDecoded(obj);
      expect(l.pageCount, 3);
      expect(l.cards.single.page, 2);
    });

    test('pageCount derived from cards when missing', () {
      final obj = {
        'cards': [_card('a', page: 0).toJson(), _card('b', page: 2).toJson()],
      };
      expect(AppLayout.fromDecoded(obj).pageCount, 3); // max page 2 -> 3 pages
    });

    test('pageCount below 1 is clamped to 1', () {
      final obj = {'pageCount': 0, 'cards': [_card('a').toJson()]};
      expect(AppLayout.fromDecoded(obj).pageCount, 1);
    });

    test('garbage falls back to the default layout', () {
      expect(AppLayout.fromDecoded('nonsense').cards, isNotEmpty);
    });
  });

  group('add / remove page', () {
    test('addPage increments and returns new index', () {
      final l = AppLayout([_card('a')])..persist = false;
      expect(l.pageCount, 1);
      expect(l.addPage(), 1);
      expect(l.pageCount, 2);
    });

    test('removePage drops its cards and shifts later pages down', () {
      final l = AppLayout(
          [_card('a', page: 0), _card('b', page: 1), _card('c', page: 2)],
          pageCount: 3)
        ..persist = false;
      l.removePage(1);
      expect(l.pageCount, 2);
      expect(l.cards.map((c) => c.id), ['a', 'c']);
      expect(l.cards.firstWhere((c) => c.id == 'c').page, 1); // shifted 2 -> 1
    });

    test('cannot delete the last remaining page', () {
      final l = AppLayout([_card('a')], pageCount: 1)..persist = false;
      l.removePage(0);
      expect(l.pageCount, 1);
      expect(l.cards, isNotEmpty);
    });

    test('activePage clamps when the active page is deleted', () {
      final l = AppLayout([_card('a', page: 0)], pageCount: 3)..persist = false;
      l.activePage = 2;
      l.removePage(2);
      expect(l.activePage, 1); // was 2, now last valid index
    });
  });

  test('addEntity places the card on the active page', () {
    final l = AppLayout([_card('a')], pageCount: 3)..persist = false;
    l.activePage = 2;
    l.addEntity('light.new');
    expect(l.cards.last.page, 2);
    expect(l.cards.last.entityId, 'light.new');
  });
}
