-- ========================================================================
-- XC TIMER · SUPABASE SCHEMA (with director password auth)
-- Run this in the Supabase SQL Editor.
-- ========================================================================

-- Enable pgcrypto for bcrypt-style hashing
create extension if not exists pgcrypto;

-- Meets: one row per race event, identified by short shareable code.
create table if not exists meets (
  code           text primary key,
  name           text not null default 'Untitled Meet',
  password_hash  text not null,                       -- bcrypt hash of director password
  created_at     timestamptz not null default now(),
  start_time     bigint,                              -- ms epoch when race started
  scored         boolean not null default false
);

-- Sessions: opaque tokens issued after password verification
create table if not exists sessions (
  token       text primary key,
  meet_code   text not null references meets(code) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default (now() + interval '24 hours')
);
create index if not exists sessions_meet_idx on sessions(meet_code);

-- Teams (schools) within a meet
create table if not exists teams (
  meet_code   text not null references meets(code) on delete cascade,
  name        text not null,
  team_index  int  not null,
  created_at  timestamptz not null default now(),
  primary key (meet_code, name)
);
create unique index if not exists teams_meet_index_uq on teams(meet_code, team_index);

-- Runners
create table if not exists runners (
  meet_code   text not null references meets(code) on delete cascade,
  bib         text not null,
  first_name  text not null,
  last_name   text not null,
  grade       text,
  gender      text,
  team        text not null,
  created_at  timestamptz not null default now(),
  primary key (meet_code, bib),
  foreign key (meet_code, team) references teams(meet_code, name) on delete cascade
);

-- Taps
create table if not exists taps (
  meet_code   text not null references meets(code) on delete cascade,
  place       int  not null,
  time_ms     bigint not null,
  created_at  timestamptz not null default now(),
  primary key (meet_code, place)
);

-- Results
create table if not exists results (
  meet_code   text not null references meets(code) on delete cascade,
  place       int  not null,
  bib         text not null,
  time_ms     bigint not null,
  recorded_at timestamptz not null default now(),
  primary key (meet_code, place),
  foreign key (meet_code, bib) references runners(meet_code, bib) on delete cascade,
  unique (meet_code, bib)
);

-- ========================================================================
-- REALTIME
-- ========================================================================
alter publication supabase_realtime add table meets;
alter publication supabase_realtime add table teams;
alter publication supabase_realtime add table runners;
alter publication supabase_realtime add table taps;
alter publication supabase_realtime add table results;

-- ========================================================================
-- ROW LEVEL SECURITY
-- Anon can READ all meet/team/runner/tap/result data (gated by knowing meet code).
-- Anon cannot WRITE directly. All writes go through SECURITY DEFINER RPCs that
-- verify a session token issued by login_meet.
-- ========================================================================
alter table meets    enable row level security;
alter table teams    enable row level security;
alter table runners  enable row level security;
alter table taps     enable row level security;
alter table results  enable row level security;
alter table sessions enable row level security;

-- READS open to anon. password_hash is in `meets` but anon will never see it
-- because the client always selects specific columns (not *).
-- To be extra safe, we expose a view that hides password_hash:
create or replace view public_meets as
  select code, name, created_at, start_time, scored from meets;
grant select on public_meets to anon;

create policy "anon read teams"    on teams    for select to anon using (true);
create policy "anon read runners"  on runners  for select to anon using (true);
create policy "anon read taps"     on taps     for select to anon using (true);
create policy "anon read results"  on results  for select to anon using (true);

-- sessions and meets have no anon policies = no direct access.

-- ========================================================================
-- AUTH RPCs
-- ========================================================================

-- Create a meet (anyone can create one; they pick the password)
create or replace function create_meet(p_code text, p_name text, p_password text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  token text;
begin
  if length(p_password) < 4 then
    raise exception 'Password must be at least 4 characters';
  end if;
  insert into meets(code, name, password_hash)
    values (p_code, coalesce(nullif(p_name, ''), 'Untitled Meet'), crypt(p_password, gen_salt('bf')));
  -- Auto-login the director
  token := encode(gen_random_bytes(24), 'hex');
  insert into sessions(token, meet_code) values (token, p_code);
  return token;
end;
$$;

-- Verify password, return session token
create or replace function login_meet(p_code text, p_password text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  stored text;
  token text;
begin
  select password_hash into stored from meets where code = p_code;
  if stored is null then
    raise exception 'Meet not found';
  end if;
  if stored <> crypt(p_password, stored) then
    raise exception 'Wrong password';
  end if;
  token := encode(gen_random_bytes(24), 'hex');
  insert into sessions(token, meet_code) values (token, p_code);
  return token;
end;
$$;

-- Internal: verify a token belongs to a meet and is unexpired
create or replace function _verify_session(p_token text, p_meet text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare ok boolean;
begin
  select true into ok from sessions
    where token = p_token and meet_code = p_meet and expires_at > now();
  if not ok then
    raise exception 'Not authorized for meet %', p_meet using errcode = '42501';
  end if;
end;
$$;

-- ========================================================================
-- WRITE RPCs (all require a session token)
-- ========================================================================

create or replace function add_tap(p_token text, p_meet text, p_time_ms bigint)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare next_place int;
begin
  perform _verify_session(p_token, p_meet);
  select coalesce(max(place), 0) + 1 into next_place from taps where meet_code = p_meet;
  insert into taps(meet_code, place, time_ms) values (p_meet, next_place, p_time_ms);
  return next_place;
end;
$$;

create or replace function add_result(p_token text, p_meet text, p_bib text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  next_place int;
  tap_time   bigint;
begin
  perform _verify_session(p_token, p_meet);
  select coalesce(max(place), 0) + 1 into next_place from results where meet_code = p_meet;
  select time_ms into tap_time from taps where meet_code = p_meet and place = next_place;
  if tap_time is null then
    raise exception 'no tap at place %', next_place;
  end if;
  insert into results(meet_code, place, bib, time_ms) values (p_meet, next_place, p_bib, tap_time);
  return next_place;
end;
$$;

create or replace function undo_result(p_token text, p_meet text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare last_place int;
begin
  perform _verify_session(p_token, p_meet);
  select max(place) into last_place from results where meet_code = p_meet;
  if last_place is null then return 0; end if;
  delete from results where meet_code = p_meet and place = last_place;
  return last_place;
end;
$$;

create or replace function register_team(p_token text, p_meet text, p_team text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  existing_idx int;
  next_idx int;
begin
  perform _verify_session(p_token, p_meet);
  select team_index into existing_idx from teams where meet_code = p_meet and name = p_team;
  if existing_idx is not null then return existing_idx; end if;
  select coalesce(max(team_index), 0) + 1 into next_idx from teams where meet_code = p_meet;
  insert into teams(meet_code, name, team_index) values (p_meet, p_team, next_idx);
  return next_idx;
end;
$$;

create or replace function add_runners(p_token text, p_meet text, p_runners jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare inserted int;
begin
  perform _verify_session(p_token, p_meet);
  with rows as (
    insert into runners(meet_code, bib, first_name, last_name, grade, gender, team)
    select p_meet, r->>'bib', r->>'first_name', r->>'last_name', r->>'grade', r->>'gender', r->>'team'
    from jsonb_array_elements(p_runners) r
    returning 1
  )
  select count(*)::int into inserted from rows;
  return inserted;
end;
$$;

create or replace function start_race(p_token text, p_meet text, p_start_time bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform _verify_session(p_token, p_meet);
  update meets set start_time = p_start_time where code = p_meet;
end;
$$;

create or replace function reset_race(p_token text, p_meet text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform _verify_session(p_token, p_meet);
  delete from results where meet_code = p_meet;
  delete from taps    where meet_code = p_meet;
  update meets set start_time = null where code = p_meet;
end;
$$;

-- Grant execute to anon
grant execute on function create_meet(text,text,text)      to anon;
grant execute on function login_meet(text,text)            to anon;
grant execute on function add_tap(text,text,bigint)        to anon;
grant execute on function add_result(text,text,text)       to anon;
grant execute on function undo_result(text,text)           to anon;
grant execute on function register_team(text,text,text)    to anon;
grant execute on function add_runners(text,text,jsonb)     to anon;
grant execute on function start_race(text,text,bigint)     to anon;
grant execute on function reset_race(text,text)            to anon;
