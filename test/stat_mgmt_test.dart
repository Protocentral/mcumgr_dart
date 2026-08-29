// Copyright (c) 2024 ProtoCentral
// SPDX-License-Identifier: MIT

import 'package:mcumgr_dart/mcumgr_dart.dart';
import 'package:test/test.dart';

import 'fake_transport.dart';

/// MCUmgr statistics group (2): `list` (id 1) and `show` (id 0), both read-only.
void main() {
  late FakeTransport t;
  late SmpClient client;
  late StatMgmt stats;

  setUp(() {
    t = FakeTransport();
    client = SmpClient(t);
    stats = StatMgmt(client);
  });

  tearDown(() => client.dispose());

  /// Run [call], answer the request it emits with [payload], and return both.
  Future<T> answer<T>(
      Future<T> Function() call, Map<String, Object?> payload) async {
    final f = call();
    await Future<void>.delayed(Duration.zero);
    t.reply(payload);
    return f;
  }

  group('list', () {
    test('sends a read to group 2 / id 1 and returns the names', () async {
      final names = await answer(stats.list, {
        'stat_list': ['smp_com', 'ble_stats']
      });

      final req = t.written.single;
      expect(req.group, 2);
      expect(req.id, 1);
      expect(req.op, SmpOp.readReq);
      expect(names, ['smp_com', 'ble_stats']);
    });

    test('a device with no groups returns empty, and does not throw', () async {
      // An empty list is a real answer. It is not the same as the group being
      // absent, which throws.
      expect(await answer(stats.list, {'stat_list': <String>[]}), isEmpty);
    });

    test('a missing or malformed stat_list degrades to empty', () async {
      expect(await answer(stats.list, {}), isEmpty);
      expect(await answer(stats.list, {'stat_list': 'nope'}), isEmpty);
    });

    test('one non-string entry does not cost the caller the whole list', () {
      expect(
        answer(stats.list, {
          'stat_list': ['ok_name', 42, null, 'other']
        }),
        completion(['ok_name', 'other']),
      );
    });
  });

  group('show', () {
    test('sends the group name and decodes integer counters', () async {
      final g = await answer(() => stats.show('smp_com'), {
        'name': 'smp_com',
        'fields': {'frame_rx': 12, 'frame_tx': 9, 'oom': 0},
      });

      final req = t.written.single;
      expect(req.group, 2);
      expect(req.id, 0);
      expect(req.op, SmpOp.readReq);
      expect(req.payload['name'], 'smp_com');

      expect(g.name, 'smp_com');
      expect(g.fields, {'frame_rx': 12, 'frame_tx': 9, 'oom': 0});
      expect(g.nonIntegerFields, isEmpty);
    });

    test('a zero counter is a value, not an absence', () async {
      // Guards the obvious mistake of filtering falsy values out of the map.
      final g = await answer(() => stats.show('s'), {
        'fields': {'errors': 0}
      });
      expect(g.fields.containsKey('errors'), isTrue);
      expect(g.fields['errors'], 0);
    });

    test('a non-integer field is preserved in raw, not silently dropped',
        () async {
      final g = await answer(() => stats.show('s'), {
        'fields': {'count': 5, 'label': 'odd'},
      });
      expect(g.fields, {'count': 5});
      expect(g.rawFields['label'], 'odd');
      expect(g.nonIntegerFields, ['label']);
    });

    test('falls back to the requested name when the device omits it', () async {
      final g = await answer(() => stats.show('asked'), {
        'fields': {'a': 1}
      });
      expect(g.name, 'asked',
          reason: 'a result must stay attributable to what was asked');
    });

    test('missing fields yields an empty group rather than throwing', () async {
      final g = await answer(() => stats.show('s'), {'name': 's'});
      expect(g.fields, isEmpty);
    });
  });

  group('errors', () {
    test('an unknown group name throws with a readable label', () async {
      // STAT_MGMT_ERR_INVALID_GROUP = 2, in group 2's own namespace.
      await expectLater(
        answer(() => stats.show('nope'), {
          'err': {'group': 2, 'rc': 2}
        }),
        throwsA(isA<SmpException>().having(
            (e) => e.toString(), 'message', contains('unknown group name'))),
      );
    });

    test('the group being absent throws ENOTSUP — a verdict, not a timeout',
        () async {
      await expectLater(
        answer(stats.list, {'rc': 8}),
        throwsA(isA<SmpException>().having((e) => e.rc, 'rc', 8)),
      );
    });
  });

  test('showAll reads every listed group', () async {
    final f = stats.showAll();
    await Future<void>.delayed(Duration.zero);
    t.reply({
      'stat_list': ['a', 'b']
    });
    await Future<void>.delayed(Duration.zero);
    t.reply({
      'name': 'a',
      'fields': {'x': 1}
    });
    await Future<void>.delayed(Duration.zero);
    t.reply({
      'name': 'b',
      'fields': {'y': 2}
    });

    final all = await f;
    expect(all.keys, ['a', 'b']);
    expect(all['a']!.fields['x'], 1);
    expect(all['b']!.fields['y'], 2);
  });
}
