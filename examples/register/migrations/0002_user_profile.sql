-- The three column kinds whose Dart shape differs between engines, so the
-- example demonstrates reading them rather than only describing it.
--
-- Column types are this engine's spelling; SQL dialect is not portable and keta
-- does not pretend otherwise. `balance` is TEXT on purpose: SQLite has no
-- exact-decimal storage (DbCapabilities.exactDecimal is false there), so a
-- NUMERIC column would hand back 12.1 for 12.10 — see UserDto.fromRow.
alter table users add column active integer not null default 1;
alter table users add column balance text;
alter table users add column created_at text;
