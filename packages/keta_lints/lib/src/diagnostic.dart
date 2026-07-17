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
///
/// [offset] and [length] locate the finding in the source (a character range),
/// so the analyzer plugin can place the squiggle exactly where the CLI's message
/// points. They default to `0` for producers (e.g. the contract-drift document
/// diff) that reason over a value with no single source span; the CLI reads only
/// [toString], so its output is unaffected by the range.
class Diagnostic {
  Diagnostic({
    required this.rule,
    required this.message,
    required this.file,
    required String scope,
    this.offset = 0,
    this.length = 0,
  }) : id = diagnosticId(file, scope, rule);
  final String id;
  final String rule;
  final String message;
  final String file;
  final int offset;
  final int length;

  @override
  String toString() => '[$id] $rule: $message ($file)';
}
