create table users (
  id text primary key,
  name text not null,
  age integer,
  role text not null,
  tags text not null default ''
);
