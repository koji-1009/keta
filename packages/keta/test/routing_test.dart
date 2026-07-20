/// `conflictKey`: the collapse rule `App.compile` uses to decide whether two
/// routes are "the same route" — literals verbatim, every capture collapsed
/// to `*` so capture names don't matter. Public so a route-table consumer
/// outside the router (keta_openapi's `OpenApi.fromRoutes`) can apply the
/// identical rule when merging routes into document path items.
library;

import 'package:keta/keta.dart';
import 'package:test/test.dart';

void main() {
  group('conflictKey', () {
    test('capture names are irrelevant to the key', () {
      // `/users/:id` and `/users/:userId` differ only in capture name; the
      // whole point of the rule is that both collapse to the same key.
      final idPath = [
        const LiteralSegment('users'),
        CaptureSegment(integer('id')),
      ];
      final userIdPath = [
        const LiteralSegment('users'),
        CaptureSegment(integer('userId')),
      ];
      expect(conflictKey('GET', idPath), conflictKey('GET', userIdPath));
    });

    test('capture type is irrelevant to the key, only position is', () {
      final intCapture = [CaptureSegment(integer('id'))];
      final stringCapture = [CaptureSegment(string('id'))];
      expect(conflictKey('GET', intCapture), conflictKey('GET', stringCapture));
    });

    test('literal segments must match verbatim', () {
      final users = [const LiteralSegment('users')];
      final orders = [const LiteralSegment('orders')];
      expect(conflictKey('GET', users), isNot(conflictKey('GET', orders)));
    });

    test('method distinguishes otherwise-identical shapes', () {
      final path = [const LiteralSegment('users')];
      expect(conflictKey('GET', path), isNot(conflictKey('POST', path)));
    });

    test('the empty (root) path has a stable key', () {
      expect(conflictKey('GET', const []), conflictKey('GET', const []));
      expect(
        conflictKey('GET', const []),
        isNot(conflictKey('POST', const [])),
      );
    });

    test('mixed literal/capture runs collapse only the captures', () {
      final byId = [
        const LiteralSegment('users'),
        CaptureSegment(integer('id')),
        const LiteralSegment('orders'),
        CaptureSegment(string('orderId')),
      ];
      final byUserId = [
        const LiteralSegment('users'),
        CaptureSegment(integer('userId')),
        const LiteralSegment('orders'),
        CaptureSegment(string('oid')),
      ];
      expect(conflictKey('GET', byId), conflictKey('GET', byUserId));
    });
  });
}
