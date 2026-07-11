library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A stable identifier for a diagnostic: the first 16 hex characters of
/// `sha256(file|scope|rule)`, so an agent can correlate the same finding across
/// runs even as line numbers move.
String diagnosticId(String file, String scope, String rule) {
  final digest = sha256.convert(utf8.encode('$file|$scope|$rule'));
  return digest.toString().substring(0, 16);
}

/// One diagnostic: a stable [id], its [rule], a [message] that includes the fix
/// instructions, and the [file] it concerns.
class Diagnostic {
  final String id;
  final String rule;
  final String message;
  final String file;

  Diagnostic({
    required this.rule,
    required this.message,
    required this.file,
    required String scope,
  }) : id = diagnosticId(file, scope, rule);

  @override
  String toString() => '[$id] $rule: $message ($file)';
}
