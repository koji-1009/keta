/// Owns the recover() middleware: which failures it treats as incidents worth
/// logging versus expected outcomes, and how a KetaException's operator-only
/// detail reaches the log without leaking to the client — plus the detail
/// contract on the KetaException subtypes recover relies on.
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  group('recover and the detail an exception carries', () {
    test('a declared status is not logged as an incident', () async {
      final env = newEnv();
      final app = App<Env>()
        ..use(recover())
        ..get('/x', (c) => throw const NotFound('nope'));
      final r = await TestClient(app, env).get('/x');
      expect(r.status, 404);
      // An expected outcome is not an incident. Logging every 404 would bury
      // the ones that matter.
      expect((env.log as MemLog).lines, isEmpty);
    });

    test('a detail reaches the operator and not the client', () async {
      final env = newEnv();
      final app = App<Env>()
        ..use(recover())
        ..get(
          '/x',
          (c) => throw const Conflict('row already exists', 'users.email'),
        );
      final r = await TestClient(app, env).get('/x');

      // The client is told the status and nothing that leaks the schema.
      expect(r.status, 409);
      expect(r.json(), {'error': 'row already exists'});
      expect(r.text(), isNot(contains('users.email')));
      // The operator is told which constraint collided. detail exists for
      // exactly this; if nothing read it, an adapter translating a driver error
      // would silently take the diagnosis with it.
      final line = (env.log as MemLog).lines.single;
      expect(line['level'], 'warn');
      expect(line['detail'], 'users.email');
      expect(line['status'], 409);
    });
  });

  test('KetaException subtypes carry detail and hide it from toString', () {
    const e = UnprocessableEntity('invalid', ['field a']);
    expect(e.status, 422);
    expect(e.detail, ['field a']);
    expect(e.toString(), 'KetaException(422, invalid)');
    expect(const BadRequest('x').detail, isNull);
    // The arbitrary-status factory keeps its status.
    expect(const KetaException.status(418, 'teapot').status, 418);
  });

  test('TransientFailure is a 503 KetaException, distinct from Unavailable', () {
    const e = TransientFailure(
      'the transaction conflicted; retry',
      'detail 40001',
    );
    // 503-family, and the detail is operator-only exactly like its siblings.
    expect(e.status, 503);
    expect(e.detail, 'detail 40001');
    expect(
      e.toString(),
      'KetaException(503, the transaction conflicted; retry)',
    );
    // Retryability is carried by the type, not a flag: a caller keys off `is
    // TransientFailure`. It shares 503 with Unavailable but is a separate type,
    // so the two are never conflated by an `is` check.
    expect(e, isA<KetaException>());
    expect(e, isA<TransientFailure>());
    expect(e, isNot(isA<Unavailable>()));
    expect(const Unavailable('x'), isNot(isA<TransientFailure>()));
  });

  test(
    'recover renders a TransientFailure as a 503 without leaking detail',
    () async {
      final env = newEnv();
      final app = App<Env>()
        ..use(recover())
        ..get(
          '/x',
          (c) => throw const TransientFailure(
            'retry the request',
            'deadlock 40P01',
          ),
        );
      final r = await TestClient(app, env).get('/x');
      expect(r.status, 503);
      expect(r.json(), {'error': 'retry the request'});
      // The SQLSTATE-bearing detail is the operator's, never the client's.
      expect(r.text(), isNot(contains('40P01')));
      // A declared status is a warn, not an error incident; its detail reaches
      // the operator exactly like the Conflict case above.
      final line = (env.log as MemLog).lines.single;
      expect(line['level'], 'warn');
      expect(line['status'], 503);
      expect(line['detail'], 'deadlock 40P01');
    },
  );

  group('the sealed set is exhaustively matchable', () {
    // This file is a different library from package:keta's own, so it sees
    // exactly what a user sees. The switch below carries NO wildcard: if any
    // member of the sealed set were unnameable from here, this would not
    // compile, which is the property StatusException was made public for.
    //
    // The compile is the assertion. A wildcard here would make the whole test
    // vacuous — it would pass no matter how many members became unreachable —
    // so it must never be added to make a future failure go away.
    String label(KetaException e) => switch (e) {
      BadRequest() => 'bad request',
      Unauthorized() => 'unauthorized',
      Forbidden() => 'forbidden',
      NotFound() => 'not found',
      Conflict() => 'conflict',
      PayloadTooLarge() => 'payload too large',
      UnprocessableEntity() => 'unprocessable',
      NotImplementedYet() => 'not implemented',
      Unavailable() => 'unavailable',
      TransientFailure() => 'transient',
      GatewayTimeout() => 'gateway timeout',
      StatusException() => 'status ${e.status}',
    };

    test('every named subtype matches its own case', () {
      expect(label(const BadRequest('x')), 'bad request');
      expect(label(const NotFound('x')), 'not found');
      expect(label(const GatewayTimeout('x')), 'gateway timeout');
    });

    test('KetaException.status lands on StatusException, not a wildcard', () {
      const e = KetaException.status(418, "I'm a teapot");
      expect(e, isA<StatusException>());
      expect(label(e), 'status 418');
      expect(e.status, 418);
      expect(e.message, "I'm a teapot");
    });

    test('a status exception carries detail like any other', () {
      const e = KetaException.status(429, 'slow down', 'bucket empty');
      expect(e.detail, 'bucket empty');
      // recover() logs the detail and withholds it from the client, exactly as
      // it does for a named subtype.
      expect(e.status, 429);
    });
  });
}
