-- ============================================================================
-- TACTICA — initial schema
-- ============================================================================
-- Design rule for this whole file: the DATABASE owns the game state.
-- Clients have NO update policy on `matches`. The only way a match changes is
-- through the SECURITY DEFINER functions at the bottom, each of which
-- re-checks whose turn it is, what the unit can do, and whether the clock ran
-- out. A client can send whatever it likes; it cannot make the board lie.
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  username   text not null unique check (char_length(username) between 2 and 20),
  is_admin   boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "profiles readable by authenticated" on public.profiles;
create policy "profiles readable by authenticated"
  on public.profiles for select to authenticated using (true);

drop policy if exists "own profile updatable" on public.profiles;
create policy "own profile updatable"
  on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Stop anyone from making themselves an admin through the normal update path.
create or replace function public.protect_admin_flag()
returns trigger language plpgsql as $$
begin
  if new.is_admin is distinct from old.is_admin then
    if coalesce(
         (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
         ''
       ) <> 'service_role'
    then
      new.is_admin := old.is_admin;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_protect_admin_flag on public.profiles;
create trigger trg_protect_admin_flag
  before update on public.profiles
  for each row execute function public.protect_admin_flag();

-- Create the profile row automatically when someone signs up.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  base text;
  candidate text;
  n int := 0;
begin
  base := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'username'), ''),
    split_part(new.email, '@', 1)
  );
  base := left(regexp_replace(base, '[^a-zA-Z0-9_\-]', '', 'g'), 16);
  if char_length(base) < 2 then base := 'player'; end if;

  candidate := base;
  while exists (select 1 from public.profiles p where p.username = candidate) loop
    n := n + 1;
    candidate := base || n::text;
  end loop;

  insert into public.profiles (id, username) values (new.id, candidate);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- cards — the roster. Admin-editable; every match reads from it.
-- ---------------------------------------------------------------------------
create table if not exists public.cards (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  hp         int  not null default 10 check (hp between 1 and 999),
  attack     int  not null default 3  check (attack between 0 and 999),
  move       int  not null default 3  check (move between 0 and 20),
  range      int  not null default 1  check (range between 1 and 20),
  ability    text not null default '',
  art_url    text,
  accent     text not null default '#7dd3fc',
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.cards enable row level security;

drop policy if exists "cards readable by authenticated" on public.cards;
create policy "cards readable by authenticated"
  on public.cards for select to authenticated using (true);

drop policy if exists "admins write cards" on public.cards;
create policy "admins write cards"
  on public.cards for all to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

-- ---------------------------------------------------------------------------
-- matches
-- ---------------------------------------------------------------------------
create table if not exists public.matches (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  host_id       uuid not null references public.profiles(id) on delete cascade,
  guest_id      uuid references public.profiles(id) on delete set null,
  host_name     text not null,
  guest_name    text,
  status        text not null default 'waiting'
                  check (status in ('waiting','active','finished')),
  state         jsonb not null,
  turn_deadline timestamptz,
  winner        text check (winner in ('host','guest')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists matches_status_idx on public.matches(status, created_at desc);

alter table public.matches enable row level security;

-- Anyone signed in can WATCH any match. That is what makes spectating work.
drop policy if exists "matches readable by authenticated" on public.matches;
create policy "matches readable by authenticated"
  on public.matches for select to authenticated using (true);

-- Deliberately NO insert/update/delete policy. All writes go through the
-- functions below, which run as the definer and bypass RLS after validating.

-- ---------------------------------------------------------------------------
-- chat
-- ---------------------------------------------------------------------------
create table if not exists public.match_messages (
  id         bigint generated always as identity primary key,
  match_id   uuid not null references public.matches(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  username   text not null,
  body       text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);

create index if not exists match_messages_match_idx
  on public.match_messages(match_id, created_at);

alter table public.match_messages enable row level security;

drop policy if exists "messages readable by authenticated" on public.match_messages;
create policy "messages readable by authenticated"
  on public.match_messages for select to authenticated using (true);

drop policy if exists "post as self" on public.match_messages;
create policy "post as self"
  on public.match_messages for insert to authenticated
  with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='matches') then
    alter publication supabase_realtime add table public.matches;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='match_messages') then
    alter publication supabase_realtime add table public.match_messages;
  end if;
end $$;

-- ============================================================================
-- GAME LOGIC
-- ============================================================================

-- Server clock, so the client countdown doesn't drift with the user's laptop.
create or replace function public.server_now()
returns timestamptz language sql stable as $$ select now() $$;

create or replace function public.gen_match_code()
returns text language plpgsql as $$
declare
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; -- no O/0/I/1
  v_code text;   -- NOT `code`: that name also belongs to matches.code, and
  i int;         -- plpgsql would not know which one the exit test meant.
begin
  loop
    v_code := '';
    for i in 1..5 loop
      v_code := v_code || substr(alphabet, 1 + floor(random() * char_length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.matches m where m.code = v_code);
  end loop;
  return v_code;
end $$;

-- Append a line to the battle log carried inside the state blob.
create or replace function public.state_log(p_state jsonb, p_text text)
returns jsonb language sql immutable as $$
  select jsonb_set(
    p_state, '{log}',
    coalesce(p_state->'log', '[]'::jsonb) || jsonb_build_object(
      'n', coalesce(jsonb_array_length(p_state->'log'), 0) + 1,
      'turn', coalesce((p_state->>'turnNumber')::int, 0),
      'text', p_text
    )
  )
$$;

-- Which side is the caller? Errors if they are only a spectator.
create or replace function public.side_of(p_match public.matches, p_user uuid)
returns text language sql immutable as $$
  select case
    when p_match.host_id  = p_user then 'host'
    when p_match.guest_id = p_user then 'guest'
    else null end
$$;

-- ---------------------------------------------------------------------------
-- create_match
-- ---------------------------------------------------------------------------
create or replace function public.create_match()
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  uid       uuid := auth.uid();
  uname     text;
  picks     public.cards[];
  c         public.cards;
  units     jsonb := '[]'::jsonb;
  st        jsonb;
  m         public.matches;
  idx       int := 0;
  lanes     int[] := array[1, 3];
begin
  if uid is null then raise exception 'not signed in'; end if;
  select username into uname from public.profiles where id = uid;
  if uname is null then raise exception 'no profile'; end if;

  -- Two random active cards, mirrored to both sides so the toy match is fair.
  select array_agg(x) into picks
  from (select * from public.cards where is_active order by random() limit 2) x;

  if picks is null or array_length(picks, 1) < 2 then
    raise exception 'roster needs at least 2 active cards';
  end if;

  foreach c in array picks loop
    idx := idx + 1;
    units := units
      || jsonb_build_object(
           'id', 'h' || idx, 'owner', 'host', 'cardId', c.id, 'name', c.name,
           'hp', c.hp, 'maxHp', c.hp, 'atk', c.attack, 'mov', c.move,
           'rng', c.range, 'accent', c.accent, 'art', c.art_url,
           'ability', c.ability,
           'x', 0, 'y', lanes[idx], 'moved', false, 'acted', false)
      || jsonb_build_object(
           'id', 'g' || idx, 'owner', 'guest', 'cardId', c.id, 'name', c.name,
           'hp', c.hp, 'maxHp', c.hp, 'atk', c.attack, 'mov', c.move,
           'rng', c.range, 'accent', c.accent, 'art', c.art_url,
           'ability', c.ability,
           'x', 6, 'y', lanes[idx], 'moved', false, 'acted', false);
  end loop;

  st := jsonb_build_object(
    'v', 1,
    'board', jsonb_build_object('w', 7, 'h', 5),
    'turn', 'host',
    'turnNumber', 0,
    'units', units,
    'log', '[]'::jsonb,
    'winner', null
  );
  st := state_log(st, uname || ' opened the arena.');

  insert into public.matches (code, host_id, host_name, state)
  values (gen_match_code(), uid, uname, st)
  returning * into m;

  return m;
end $$;

-- ---------------------------------------------------------------------------
-- join_match
-- ---------------------------------------------------------------------------
create or replace function public.join_match(p_code text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  uid   uuid := auth.uid();
  uname text;
  m     public.matches;
  st    jsonb;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select username into uname from public.profiles where id = uid;

  select * into m from public.matches
   where code = upper(trim(p_code)) for update;
  if m.id is null then raise exception 'no room with that code'; end if;

  -- Rejoining your own match is fine and is a no-op.
  if m.host_id = uid or m.guest_id = uid then return m; end if;
  if m.status <> 'waiting' then raise exception 'that room is already full'; end if;

  st := state_log(m.state, uname || ' entered the arena.');
  st := state_log(st, 'Turn 1 — ' || m.host_name || ' to act.');
  st := jsonb_set(st, '{turnNumber}', '1'::jsonb);

  update public.matches
     set guest_id = uid, guest_name = uname, status = 'active',
         state = st, turn_deadline = now() + interval '30 seconds',
         updated_at = now()
   where id = m.id
   returning * into m;

  return m;
end $$;

-- ---------------------------------------------------------------------------
-- submit_move
-- ---------------------------------------------------------------------------
create or replace function public.submit_move(p_match uuid, p_unit text, p_x int, p_y int)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  uid   uuid := auth.uid();
  m     public.matches;
  side  text;
  st    jsonb;
  units jsonb;
  u     jsonb;
  found jsonb;
  out_u jsonb := '[]'::jsonb;
  dist  int;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;

  side := side_of(m, uid);
  if side is null then raise exception 'you are spectating this match'; end if;
  if m.state->>'turn' <> side then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then
    raise exception 'your time ran out';
  end if;

  st := m.state;
  units := st->'units';

  for u in select * from jsonb_array_elements(units) loop
    if u->>'id' = p_unit then found := u; end if;
  end loop;

  if found is null then raise exception 'no such unit'; end if;
  if found->>'owner' <> side then raise exception 'that is not your unit'; end if;
  if (found->>'moved')::boolean then raise exception 'that unit already moved'; end if;

  if p_x < 0 or p_y < 0
     or p_x >= (st->'board'->>'w')::int
     or p_y >= (st->'board'->>'h')::int then
    raise exception 'off the board';
  end if;

  dist := abs(p_x - (found->>'x')::int) + abs(p_y - (found->>'y')::int);
  if dist = 0 then raise exception 'already there'; end if;
  if dist > (found->>'mov')::int then raise exception 'too far for that unit'; end if;

  for u in select * from jsonb_array_elements(units) loop
    if (u->>'x')::int = p_x and (u->>'y')::int = p_y then
      raise exception 'that tile is occupied';
    end if;
  end loop;

  for u in select * from jsonb_array_elements(units) loop
    if u->>'id' = p_unit then
      u := jsonb_set(u, '{x}', to_jsonb(p_x));
      u := jsonb_set(u, '{y}', to_jsonb(p_y));
      u := jsonb_set(u, '{moved}', 'true'::jsonb);
    end if;
    out_u := out_u || u;
  end loop;

  st := jsonb_set(st, '{units}', out_u);
  st := state_log(st, (found->>'name') || ' advances.');

  update public.matches set state = st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

-- ---------------------------------------------------------------------------
-- submit_attack
-- ---------------------------------------------------------------------------
create or replace function public.submit_attack(p_match uuid, p_unit text, p_target text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  uid    uuid := auth.uid();
  m      public.matches;
  side   text;
  st     jsonb;
  units  jsonb;
  u      jsonb;
  atk    jsonb;
  tgt    jsonb;
  out_u  jsonb := '[]'::jsonb;
  dist   int;
  dmg    int;
  newhp  int;
  killed boolean := false;
  foes   int := 0;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;

  side := side_of(m, uid);
  if side is null then raise exception 'you are spectating this match'; end if;
  if m.state->>'turn' <> side then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then
    raise exception 'your time ran out';
  end if;

  st := m.state;
  units := st->'units';

  for u in select * from jsonb_array_elements(units) loop
    if u->>'id' = p_unit   then atk := u; end if;
    if u->>'id' = p_target then tgt := u; end if;
  end loop;

  if atk is null or tgt is null then raise exception 'unit not found'; end if;
  if atk->>'owner' <> side then raise exception 'that is not your unit'; end if;
  if tgt->>'owner' = side then raise exception 'no friendly fire'; end if;
  if (atk->>'acted')::boolean then raise exception 'that unit already attacked'; end if;

  dist := abs((atk->>'x')::int - (tgt->>'x')::int)
        + abs((atk->>'y')::int - (tgt->>'y')::int);
  if dist > (atk->>'rng')::int then raise exception 'target is out of range'; end if;

  dmg   := (atk->>'atk')::int;
  newhp := (tgt->>'hp')::int - dmg;
  killed := newhp <= 0;

  for u in select * from jsonb_array_elements(units) loop
    if u->>'id' = p_unit then
      u := jsonb_set(u, '{acted}', 'true'::jsonb);
      u := jsonb_set(u, '{moved}', 'true'::jsonb); -- attacking ends that unit's turn
      out_u := out_u || u;
    elsif u->>'id' = p_target then
      if not killed then
        out_u := out_u || jsonb_set(u, '{hp}', to_jsonb(newhp));
      end if; -- dropped from the array when killed
    else
      out_u := out_u || u;
    end if;
  end loop;

  st := jsonb_set(st, '{units}', out_u);
  st := state_log(st,
    (atk->>'name') || ' hits ' || (tgt->>'name') || ' for ' || dmg
    || case when killed then ' — destroyed.' else '.' end);

  -- Win check: does the other side have anything left?
  for u in select * from jsonb_array_elements(out_u) loop
    if u->>'owner' <> side then foes := foes + 1; end if;
  end loop;

  if foes = 0 then
    st := jsonb_set(st, '{winner}', to_jsonb(side));
    st := state_log(st,
      case when side = 'host' then m.host_name else m.guest_name end || ' wins.');
    update public.matches
       set state = st, status = 'finished', winner = side,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
  else
    update public.matches set state = st, updated_at = now()
     where id = m.id returning * into m;
  end if;

  return m;
end $$;

-- ---------------------------------------------------------------------------
-- Shared turn-advance used by end_turn and force_timeout.
-- ---------------------------------------------------------------------------
create or replace function public.advance_turn(p_match uuid, p_note text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m      public.matches;
  st     jsonb;
  u      jsonb;
  out_u  jsonb := '[]'::jsonb;
  nxt    text;
  tn     int;
begin
  select * into m from public.matches where id = p_match for update;
  st  := m.state;
  nxt := case when st->>'turn' = 'host' then 'guest' else 'host' end;
  tn  := coalesce((st->>'turnNumber')::int, 1) + 1;

  for u in select * from jsonb_array_elements(st->'units') loop
    u := jsonb_set(u, '{moved}', 'false'::jsonb);
    u := jsonb_set(u, '{acted}', 'false'::jsonb);
    out_u := out_u || u;
  end loop;

  st := jsonb_set(st, '{units}', out_u);
  st := jsonb_set(st, '{turn}', to_jsonb(nxt));
  st := jsonb_set(st, '{turnNumber}', to_jsonb(tn));
  if p_note is not null then st := state_log(st, p_note); end if;
  st := state_log(st, 'Turn ' || tn || ' — '
        || case when nxt = 'host' then m.host_name else m.guest_name end || ' to act.');

  update public.matches
     set state = st, turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

create or replace function public.end_turn(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; side text;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  side := side_of(m, auth.uid());
  if side is null then raise exception 'you are spectating this match'; end if;
  if m.state->>'turn' <> side then raise exception 'not your turn'; end if;
  return advance_turn(p_match, null);
end $$;

-- Anyone watching may call this, but it only does something once the clock has
-- genuinely expired according to the SERVER. That is the whole 30-second rule:
-- no cron job, no game server, and no way for a client to trigger it early.
create or replace function public.force_timeout(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; loser text;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then return m; end if;
  if m.turn_deadline is null then return m; end if;
  if now() <= m.turn_deadline + interval '2 seconds' then return m; end if;

  loser := case when m.state->>'turn' = 'host' then m.host_name else m.guest_name end;
  return advance_turn(p_match, loser || ' ran out of time.');
end $$;

create or replace function public.resign_match(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; side text; win text; st jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  side := side_of(m, auth.uid());
  if side is null then raise exception 'you are spectating this match'; end if;
  if m.status <> 'active' then return m; end if;

  win := case when side = 'host' then 'guest' else 'host' end;
  st := state_log(m.state,
        case when side = 'host' then m.host_name else m.guest_name end
        || ' resigned. '
        || case when win = 'host' then m.host_name else m.guest_name end || ' wins.');
  st := jsonb_set(st, '{winner}', to_jsonb(win));

  update public.matches
     set state = st, status = 'finished', winner = win,
         turn_deadline = null, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

-- ---------------------------------------------------------------------------
-- Seed roster — placeholder cards so there is something to fight with.
-- Replace these from the admin panel once it exists.
-- ---------------------------------------------------------------------------
insert into public.cards (name, hp, attack, move, range, ability, accent)
select * from (values
  ('Vanguard',  14, 4, 3, 1, 'Holds the line.',              '#f0abfc'),
  ('Skirmisher',10, 3, 4, 1, 'Fast, fragile.',               '#7dd3fc'),
  ('Archer',     8, 4, 2, 3, 'Strikes from a distance.',     '#fde68a'),
  ('Bulwark',   18, 2, 2, 1, 'Slow, very hard to remove.',   '#a7f3d0')
) as v(name, hp, attack, move, range, ability, accent)
where not exists (select 1 from public.cards);

-- ---------------------------------------------------------------------------
-- Lock down internals. advance_turn in particular MUST NOT be callable
-- directly, or a player could skip their opponent's turn with one API call.
-- The public entry points call it from inside a definer context, so they still
-- work. Everything a client is allowed to do is in the grant list below.
-- ---------------------------------------------------------------------------
revoke execute on function public.advance_turn(uuid, text)  from public, anon, authenticated;
revoke execute on function public.state_log(jsonb, text)    from public, anon, authenticated;
revoke execute on function public.side_of(public.matches, uuid) from public, anon, authenticated;
revoke execute on function public.gen_match_code()          from public, anon, authenticated;

grant execute on function public.create_match()                        to authenticated;
grant execute on function public.join_match(text)                      to authenticated;
grant execute on function public.submit_move(uuid, text, int, int)     to authenticated;
grant execute on function public.submit_attack(uuid, text, text)       to authenticated;
grant execute on function public.end_turn(uuid)                        to authenticated;
grant execute on function public.force_timeout(uuid)                   to authenticated;
grant execute on function public.resign_match(uuid)                    to authenticated;
grant execute on function public.server_now()                          to authenticated;
