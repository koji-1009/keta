library;

/// The seven HTTP methods keta_lints treats as route verbs.
///
/// Shared by drift.dart (contract-drift's operation-key filter), generate.dart
/// (the scaffold's route-table walk), routes_lint.dart and query_lint.dart and
/// request_body_lint.dart (the `app.<verb>(...)` matcher) — one const rather
/// than a literal per producer, so the set cannot drift apart between them.
const httpMethods = {
  'get',
  'post',
  'put',
  'delete',
  'patch',
  'head',
  'options',
};
