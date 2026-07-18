/// `conflictKey` parity with keta core: keta_openapi hand-copies keta's
/// route-conflict collapse rule because it is not part of keta's public API,
/// so this pins the copy against a corpus rather than trusting it never to
/// drift.
library;

import 'package:keta/keta.dart';
// A workspace-internal test may reach into keta's `src/` to pin behavior that
// the public API does not export. `conflictKey` is exactly that: `App.compile`
// keys route-conflict detection off it, but it is deliberately not part of
// `package:keta/keta.dart`. keta_openapi hand-copies it as `openapi.dart`'s
// `conflictKey`; nothing would break if keta changed its collapse rule and the
// copy drifted. This test closes that channel by asserting the two produce
// identical keys over a corpus. See the doc on both functions.
import 'package:keta/src/routing.dart' as keta;
import 'package:keta_openapi/src/openapi.dart' as openapi;
import 'package:test/test.dart';

void main() {
  group('conflictKey parity with keta core', () {
    // Segment lists spanning every axis the collapse rule touches: bare
    // literals, a single capture, adjacent captures, captures whose names
    // differ (must collapse to the SAME key — the whole point of the rule),
    // mixed literal/capture runs, and the empty (root) path.
    final corpus = <List<Segment>>[
      const [],
      const [LiteralSegment('users')],
      const [LiteralSegment('api'), LiteralSegment('v1'), LiteralSegment('x')],
      const [CaptureSegment(integer)],
      [CaptureSegment(integer('id'))],
      [CaptureSegment(integer('userId'))],
      [CaptureSegment(string('name'))],
      const [CaptureSegment(integer), CaptureSegment(number)],
      [CaptureSegment(integer('a')), CaptureSegment(number('b'))],
      [const LiteralSegment('users'), CaptureSegment(integer('id'))],
      [
        const LiteralSegment('users'),
        CaptureSegment(integer('id')),
        const LiteralSegment('orders'),
        CaptureSegment(string('orderId')),
      ],
    ];

    for (final method in const ['GET', 'POST', 'DELETE']) {
      for (var i = 0; i < corpus.length; i++) {
        test('$method corpus[$i] agrees', () {
          expect(
            openapi.conflictKey(method, corpus[i]),
            keta.conflictKey(method, corpus[i]),
          );
        });
      }
    }

    test('capture-name variants collapse to one shared key in both', () {
      // `/users/:id` and `/users/:userId` differ only in capture name; the rule
      // collapses both to the same key so they count as one conflict. Assert
      // that collapse happens identically on both sides — the exact drift a
      // silent hand-copy would let slip.
      final idPath = [
        const LiteralSegment('users'),
        CaptureSegment(integer('id')),
      ];
      final userIdPath = [
        const LiteralSegment('users'),
        CaptureSegment(integer('userId')),
      ];
      expect(
        openapi.conflictKey('GET', idPath),
        openapi.conflictKey('GET', userIdPath),
      );
      expect(
        keta.conflictKey('GET', idPath),
        keta.conflictKey('GET', userIdPath),
      );
      expect(
        openapi.conflictKey('GET', idPath),
        keta.conflictKey('GET', userIdPath),
      );
    });
  });
}
