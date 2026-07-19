library;

/// The seven HTTP methods keta_lints treats as route verbs.
///
/// Shared by drift.dart (contract-drift's operation-key filter),
/// generate.dart (the scaffold's route-table walk), routes_lint.dart (the
/// `app.<verb>(...)` matcher), and query_lint.dart (same matcher, for query
/// params) — one const rather than four independently-typed literals, so the
/// set cannot silently drift apart across the four producers (it had:
/// duplicated, unexported, byte-for-byte identical, and therefore only as
/// consistent as four manual edits happened to stay).
const httpMethods = {
  'get',
  'post',
  'put',
  'delete',
  'patch',
  'head',
  'options',
};
