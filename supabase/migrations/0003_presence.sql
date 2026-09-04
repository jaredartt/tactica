-- ############################################################################
-- HOW TO RUN THIS
--   1. Paste the WHOLE file into the Supabase SQL editor and press Run.
--   2. A dark box may appear: "Potential issue detected ... destructive
--      operations". That is expected -- removing empty rooms is the point of
--      this file. Click the "Run query" button in that box, NOT "Cancel".
--      Nothing runs until you click it.
--   3. The Results pane at the bottom will show whether it worked.
-- ############################################################################

-- ============================================================================
-- 0003 -- rooms clean themselves up
-- ============================================================================
-- Nothing in the schema knew whether a human was actually sitting in a room,
-- so an abandoned one lived forever. This adds the smallest thing that can
-- answer that question: a heartbeat per PLAYER (spectators do not count -- a
-- room with only watchers in it has no players and should go).
--
-- Two mechanisms, because one is not enough:
--   * leaving deliberately deletes the room straight away, and
--   * a sweep catches closed tabs, crashes and lost connections.
--
-- Safe to run twice.
-- ============================================================================

create table if not exists public.match_presence (
  match_id uuid not null references public.matches(id) on delete cascade,
  user_id  uuid not null references public.profiles(id) on delete cascade,
  side     text not null check (side in ('host','guest')),
  seen_at  timestamptz not null default now(),
  primary key (match_id, user_id)
);

create index if not exists match_presence_seen_idx on public.match_presence(match_id, seen_at desc);

-- Deliberately NOT in the realtime publication: a heartbeat every ten seconds
-- would otherwise be broadcast to every subscriber of every match.
alter table public.match_presence enable row level security;
-- and deliberately no policies: clients reach this only through the functions
-- below, so nobody can forge someone else's presence.

-- How long a player can be silent before the room stops counting them. Long
-- enough to survive a page refresh or a phone unlocking, short enough that an
-- abandoned room is gone before anyone notices it.
create or replace function public.presence_grace() returns interval
language sql immutable as $$ select interval '45 seconds' $$;

-- ---------------------------------------------------------------------------
-- touch_match -- "I am still here". No-op for spectators.
-- ---------------------------------------------------------------------------
create or replace function public.touch_match(p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m public.matches; s text;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null then return; end if;
  s := side_of(m, auth.uid());
  if s is null then return; end if;             -- spectators do not hold a room open
  insert into public.match_presence (match_id, user_id, side, seen_at)
  values (p_match, auth.uid(), s, now())
  on conflict (match_id, user_id) do update set seen_at = now();
end $$;

-- ---------------------------------------------------------------------------
-- leave_match -- deliberate exit. Drops the room immediately if it empties.
-- ---------------------------------------------------------------------------
create or replace function public.leave_match(p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.match_presence
   where match_id = p_match and user_id = auth.uid();

  delete from public.matches m
   where m.id = p_match
     and not exists (
       select 1 from public.match_presence p
        where p.match_id = m.id and p.seen_at > now() - presence_grace());
end $$;

-- ---------------------------------------------------------------------------
-- sweep_matches -- the safety net for tabs that were closed, not left.
-- Anyone signed in may call it; it can only ever remove rooms that no player
-- has touched inside the grace window, so calling it cannot hurt a live game.
-- ---------------------------------------------------------------------------
create or replace function public.sweep_matches()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with gone as (
    delete from public.matches m
     where not exists (
       select 1 from public.match_presence p
        where p.match_id = m.id and p.seen_at > now() - presence_grace())
    returning 1)
  select count(*) into n from gone;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Existing rooms have no presence rows at all, so seed the two entry points
-- to record it from the moment a room exists -- otherwise a brand new room
-- would be swept before its first heartbeat.
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
           'x', 4, 'y', lanes[idx], 'moved', false, 'acted', false);
  end loop;

  st := jsonb_build_object(
    'v', 1,
    'board', jsonb_build_object('w', 5, 'h', 5),
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

  insert into public.match_presence (match_id, user_id, side)
  values (m.id, uid, 'host');

  return m;
end $$;

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

  if m.host_id = uid or m.guest_id = uid then
    perform touch_match(m.id);
    return m;
  end if;
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

  insert into public.match_presence (match_id, user_id, side)
  values (m.id, uid, 'guest')
  on conflict (match_id, user_id) do update set seen_at = now();

  return m;
end $$;

revoke execute on function public.presence_grace() from public, anon, authenticated;
grant  execute on function public.touch_match(uuid)  to authenticated;
grant  execute on function public.leave_match(uuid)  to authenticated;
grant  execute on function public.sweep_matches()    to authenticated;

-- The rooms that are already stranded have no presence rows, so this clears
-- them out the first time the file is run.
select public.sweep_matches();


-- ---------------------------------------------------------------------------
-- Did it work? These three values are the answer -- all true / 0 means yes.
-- ---------------------------------------------------------------------------
select
  to_regclass('public.match_presence')      is not null as presence_table_created,
  to_regprocedure('public.sweep_matches()') is not null as sweep_created,
  to_regprocedure('public.leave_match(uuid)') is not null as leave_created,
  (select count(*) from public.matches)                 as rooms_left;
