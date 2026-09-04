-- ============================================================================
-- 0004 -- hidden rating, visible ladder, results, rematch
-- ============================================================================
-- Two numbers per player, doing different jobs:
--
--   mmr  (hidden)  Elo. Zero-sum, never shown to other players. This is the
--                  honest estimate of how good you are, and it is what decides
--                  how much a result is worth.
--   lp   (visible) The ladder. Gains and losses are scaled by the SAME Elo
--                  expectation, so beating a beginner is worth ~4 and beating
--                  someone far above you is worth ~40. LP is zero-sum too,
--                  which matters here because there is no matchmaking: players
--                  choose each other by room code, so nothing stops two friends
--                  from playing repeatedly. If a win paid more than a loss
--                  cost, they would both climb forever.
--
-- The "ladder mostly climbs" feeling comes from TIER FLOORS instead: once you
-- reach a tier you cannot drop out of it for the rest of the season. That is a
-- bounded, deliberate leak rather than an open one.
--
-- Safe to run twice.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- season
-- ---------------------------------------------------------------------------
create table if not exists public.app_settings (
  id     boolean primary key default true check (id),
  season int not null default 1
);
insert into public.app_settings (id) values (true) on conflict (id) do nothing;

alter table public.app_settings enable row level security;
drop policy if exists "settings readable" on public.app_settings;
create policy "settings readable" on public.app_settings for select to authenticated using (true);

create or replace function public.current_season() returns int
language sql stable as $$ select season from public.app_settings where id $$;

-- ---------------------------------------------------------------------------
-- the visible ladder lives on the profile; the hidden rating does not
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists lp        int not null default 0;
alter table public.profiles add column if not exists floor_lp  int not null default 0;
alter table public.profiles add column if not exists wins      int not null default 0;
alter table public.profiles add column if not exists losses    int not null default 0;
alter table public.profiles add column if not exists games     int not null default 0;
alter table public.profiles add column if not exists streak    int not null default 0;
alter table public.profiles add column if not exists season    int not null default 1;

create index if not exists profiles_lp_idx on public.profiles(lp desc, wins desc);

-- Hidden on purpose: its own table, readable only by its owner. Everyone can
-- see everyone's LP; nobody can see anyone else's underlying rating.
create table if not exists public.player_rating (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  mmr     int not null default 1000,
  games   int not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.player_rating enable row level security;
drop policy if exists "own rating readable" on public.player_rating;
create policy "own rating readable" on public.player_rating
  for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- tiers
-- ---------------------------------------------------------------------------
create or replace function public.tier_of(p_lp int) returns text
language sql immutable as $$
  select case
    when p_lp >= 1500 then 'Crown'
    when p_lp >= 1200 then 'Diamond'
    when p_lp >=  900 then 'Platinum'
    when p_lp >=  600 then 'Gold'
    when p_lp >=  300 then 'Silver'
    else 'Bronze' end
$$;

create or replace function public.tier_floor(p_lp int) returns int
language sql immutable as $$
  select case
    when p_lp >= 1500 then 1500
    when p_lp >= 1200 then 1200
    when p_lp >=  900 then 900
    when p_lp >=  600 then 600
    when p_lp >=  300 then 300
    else 0 end
$$;

-- Probability that A beats B, straight out of Elo.
create or replace function public.expected_score(p_a int, p_b int) returns numeric
language sql immutable as $$
  select 1.0 / (1.0 + power(10.0, (p_b - p_a)::numeric / 400.0))
$$;

-- ---------------------------------------------------------------------------
-- results outlive the room they were played in
-- ---------------------------------------------------------------------------
create table if not exists public.match_results (
  id           bigint generated always as identity primary key,
  code         text,
  season       int not null default 1,
  winner_id    uuid references public.profiles(id) on delete set null,
  loser_id     uuid references public.profiles(id) on delete set null,
  winner_name  text not null,
  loser_name   text not null,
  winner_lp    int not null,
  loser_lp     int not null,
  reason       text not null check (reason in ('defeat','resign')),
  created_at   timestamptz not null default now()
);
create index if not exists match_results_recent_idx on public.match_results(created_at desc);

alter table public.match_results enable row level security;
drop policy if exists "results readable" on public.match_results;
create policy "results readable" on public.match_results for select to authenticated using (true);

-- ---------------------------------------------------------------------------
-- finish_match -- the ONLY place a result is ever recorded.
-- Internal: revoked from clients at the bottom of this file.
-- ---------------------------------------------------------------------------
create or replace function public.finish_match(p_match uuid, p_winner text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  m public.matches;
  w_id uuid; l_id uuid; w_name text; l_name text;
  w_mmr int; l_mmr int; w_g int; l_g int;
  e_w numeric; swing int;
  w_lp int; l_lp int; w_floor int; l_floor int;
  w_lp_new int; l_lp_new int;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null or m.guest_id is null then return; end if;
  if m.status = 'finished' then return; end if;   -- never rate a match twice

  if p_winner = 'host' then
    w_id := m.host_id;  l_id := m.guest_id; w_name := m.host_name;  l_name := m.guest_name;
  else
    w_id := m.guest_id; l_id := m.host_id;  w_name := m.guest_name; l_name := m.host_name;
  end if;
  if w_id = l_id then return; end if;

  insert into public.player_rating (user_id) values (w_id) on conflict (user_id) do nothing;
  insert into public.player_rating (user_id) values (l_id) on conflict (user_id) do nothing;
  select mmr, games into w_mmr, w_g from public.player_rating where user_id = w_id;
  select mmr, games into l_mmr, l_g from public.player_rating where user_id = l_id;

  e_w := expected_score(w_mmr, l_mmr);

  -- Hidden rating. K is larger while a player is still being placed, so a
  -- misjudged newcomer converges in a handful of games instead of fifty.
  update public.player_rating
     set mmr = round(w_mmr + (case when w_g < 10 then 40 else 20 end) * (1 - e_w)),
         games = games + 1, updated_at = now()
   where user_id = w_id;
  update public.player_rating
     set mmr = round(l_mmr - (case when l_g < 10 then 40 else 20 end) * (1 - e_w)),
         games = games + 1, updated_at = now()
   where user_id = l_id;

  -- Visible ladder. One number, applied to both, so LP is zero-sum before
  -- floors: 28 points scaled by how surprising the result was, clamped so no
  -- single game is meaningless or catastrophic.
  swing := greatest(4, least(40, round(28 * (1 - e_w))::int));

  select lp, floor_lp into w_lp, w_floor from public.profiles where id = w_id;
  select lp, floor_lp into l_lp, l_floor from public.profiles where id = l_id;

  w_lp_new := w_lp + swing;
  l_lp_new := greatest(l_floor, greatest(0, l_lp - swing));   -- the tier floor

  update public.profiles
     set lp = w_lp_new,
         floor_lp = greatest(w_floor, tier_floor(w_lp_new)),
         wins = wins + 1, games = games + 1,
         streak = case when streak >= 0 then streak + 1 else 1 end
   where id = w_id;

  update public.profiles
     set lp = l_lp_new,
         losses = losses + 1, games = games + 1,
         streak = case when streak <= 0 then streak - 1 else -1 end
   where id = l_id;

  insert into public.match_results
    (code, season, winner_id, loser_id, winner_name, loser_name,
     winner_lp, loser_lp, reason)
  values
    (m.code, current_season(), w_id, l_id, w_name, l_name,
     swing, l_lp_new - l_lp, p_reason);
end $$;

-- ---------------------------------------------------------------------------
-- a fresh board, shared by opening a room and by a rematch so the two can
-- never drift apart
-- ---------------------------------------------------------------------------
create or replace function public.fresh_board_state()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  picks public.cards[]; c public.cards;
  units jsonb := '[]'::jsonb; idx int := 0; lanes int[] := array[1, 3];
begin
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

  return jsonb_build_object(
    'v', 1, 'board', jsonb_build_object('w', 5, 'h', 5),
    'turn', 'host', 'turnNumber', 0, 'units', units,
    'log', '[]'::jsonb, 'winner', null);
end $$;

create or replace function public.create_match()
returns public.matches
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); uname text; st jsonb; m public.matches;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select username into uname from public.profiles where id = uid;
  if uname is null then raise exception 'no profile'; end if;

  st := state_log(fresh_board_state(), uname || ' opened the arena.');

  insert into public.matches (code, host_id, host_name, state)
  values (gen_match_code(), uid, uname, st)
  returning * into m;

  insert into public.match_presence (match_id, user_id, side)
  values (m.id, uid, 'host') on conflict (match_id, user_id) do update set seen_at = now();

  return m;
end $$;

-- ---------------------------------------------------------------------------
-- rematch: both players have to want it. Asking sets your flag; the second
-- flag creates the new room and points the old one at it, so both clients
-- find it through the realtime update they are already listening to. No new
-- channel, no invitation to accept, no race.
-- ---------------------------------------------------------------------------
alter table public.matches add column if not exists rematch_host  boolean not null default false;
alter table public.matches add column if not exists rematch_guest boolean not null default false;
alter table public.matches add column if not exists next_match_id uuid;

create or replace function public.request_rematch(p_match uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare m public.matches; s text; st jsonb; nm public.matches;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'finished' then raise exception 'that match is still running'; end if;
  s := side_of(m, auth.uid());
  if s is null then raise exception 'you are spectating this match'; end if;
  if m.next_match_id is not null then return m.next_match_id; end if;

  if s = 'host'
    then update public.matches set rematch_host  = true where id = p_match;
    else update public.matches set rematch_guest = true where id = p_match;
  end if;

  select * into m from public.matches where id = p_match;
  if not (m.rematch_host and m.rematch_guest) then return null; end if;

  -- Sides swap, so nobody keeps the first-move advantage two games running.
  st := fresh_board_state();
  st := state_log(st, 'Rematch. ' || m.guest_name || ' moves first.');
  st := state_log(st, 'Turn 1 — ' || m.guest_name || ' to act.');
  st := jsonb_set(st, '{turnNumber}', '1'::jsonb);

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline)
  values
    (gen_match_code(), m.guest_id, m.guest_name, m.host_id, m.host_name,
     'active', st, now() + interval '30 seconds')
  returning * into nm;

  insert into public.match_presence (match_id, user_id, side) values
    (nm.id, nm.host_id, 'host'), (nm.id, nm.guest_id, 'guest')
  on conflict (match_id, user_id) do update set seen_at = now();

  update public.matches set next_match_id = nm.id where id = p_match;
  return nm.id;
end $$;

-- ---------------------------------------------------------------------------
-- the leaderboard
-- ---------------------------------------------------------------------------
drop view if exists public.leaderboard;
create view public.leaderboard
with (security_invoker = true) as
  select p.id, p.username, p.lp, tier_of(p.lp) as tier,
         p.wins, p.losses, p.games, p.streak
    from public.profiles p
   where p.games > 0;
grant select on public.leaderboard to authenticated;

-- Admin-only, for when you want to wipe the ladder and keep the ratings.
create or replace function public.start_new_season()
returns int language plpgsql security definer set search_path = public as $$
declare s int;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and is_admin) then
    raise exception 'admins only';
  end if;
  update public.app_settings set season = season + 1 where id returning season into s;
  update public.profiles set lp = 0, floor_lp = 0, streak = 0, season = s;
  return s;
end $$;

-- Supabase grants table privileges to `authenticated` by default and leans on
-- RLS to constrain them; say it explicitly here so the intent is readable and
-- does not depend on when a table happened to be created.
grant select on public.player_rating  to authenticated;   -- RLS: your row only
grant select on public.match_results  to authenticated;
grant select on public.app_settings   to authenticated;
revoke insert, update, delete on public.player_rating from authenticated;
revoke insert, update, delete on public.match_results from authenticated;
revoke insert, update, delete on public.app_settings  from authenticated;
revoke all on public.match_presence from authenticated; -- functions only

revoke execute on function public.finish_match(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.fresh_board_state()              from public, anon, authenticated;
revoke execute on function public.expected_score(int, int)         from public, anon, authenticated;
revoke execute on function public.tier_floor(int)                  from public, anon, authenticated;
grant  execute on function public.request_rematch(uuid) to authenticated;
grant  execute on function public.current_season()      to authenticated;
grant  execute on function public.tier_of(int)          to authenticated;
grant  execute on function public.start_new_season()    to authenticated;

-- ---------------------------------------------------------------------------
-- The two places a match can end now both record the result. finish_match is
-- called BEFORE the status flips to 'finished', because it refuses to rate a
-- match that is already finished -- that guard is what makes a double call
-- harmless.
-- ---------------------------------------------------------------------------
create or replace function public.submit_attack(p_match uuid, p_unit text, p_target text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  m public.matches; side text; other text;
  st jsonb; units jsonb; u jsonb; atk jsonb; tgt jsonb;
  out_u jsonb := '[]'::jsonb;
  dist int; dmg int; tgt_hp int; atk_hp int; counter int := 0;
  killed_tgt boolean := false; killed_atk boolean := false;
  foes int := 0; mine int := 0; win text;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;

  side := side_of(m, uid);
  if side is null then raise exception 'you are spectating this match'; end if;
  other := case when side = 'host' then 'guest' else 'host' end;
  if m.state->>'turn' <> side then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then
    raise exception 'your time ran out';
  end if;

  st := m.state; units := st->'units';
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

  dmg := (atk->>'atk')::int;
  tgt_hp := (tgt->>'hp')::int - dmg;
  killed_tgt := tgt_hp <= 0;
  atk_hp := (atk->>'hp')::int;

  if not killed_tgt
     and dist <= (tgt->>'rng')::int
     and (tgt->>'rng')::int >= (atk->>'rng')::int then
    counter := (tgt->>'atk')::int;
    atk_hp := atk_hp - counter;
    killed_atk := atk_hp <= 0;
  end if;

  for u in select * from jsonb_array_elements(units) loop
    if u->>'id' = p_unit then
      if not killed_atk then
        u := jsonb_set(u, '{acted}', 'true'::jsonb);
        u := jsonb_set(u, '{moved}', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb(atk_hp));
        out_u := out_u || u;
      end if;
    elsif u->>'id' = p_target then
      if not killed_tgt then
        out_u := out_u || jsonb_set(u, '{hp}', to_jsonb(tgt_hp));
      end if;
    else
      out_u := out_u || u;
    end if;
  end loop;

  st := jsonb_set(st, '{units}', out_u);
  st := jsonb_set(st, '{fx}', jsonb_build_object(
    'seq', coalesce((st->'fx'->>'seq')::int, 0) + 1,
    'atk', p_unit, 'tgt', p_target, 'dmg', dmg,
    'killedTgt', killed_tgt, 'counter', counter, 'killedAtk', killed_atk));

  st := state_log(st,
    (atk->>'name') || ' hits ' || (tgt->>'name') || ' for ' || dmg
    || case when killed_tgt then ' -- destroyed.' else '.' end);
  if counter > 0 then
    st := state_log(st,
      (tgt->>'name') || ' counters for ' || counter
      || case when killed_atk then ' -- ' || (atk->>'name') || ' destroyed.' else '.' end);
  end if;

  for u in select * from jsonb_array_elements(out_u) loop
    if u->>'owner' = side then mine := mine + 1; else foes := foes + 1; end if;
  end loop;

  if foes = 0 then win := side;
  elsif mine = 0 then win := other;
  end if;

  if win is not null then
    perform finish_match(m.id, win, 'defeat');
    st := jsonb_set(st, '{winner}', to_jsonb(win));
    st := state_log(st,
      case when win = 'host' then m.host_name else m.guest_name end || ' wins.');
    update public.matches
       set state = st, status = 'finished', winner = win,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
  else
    update public.matches set state = st, updated_at = now()
     where id = m.id returning * into m;
  end if;

  return m;
end $$;

create or replace function public.resign_match(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare m public.matches; side text; win text; st jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  side := side_of(m, auth.uid());
  if side is null then raise exception 'you are spectating this match'; end if;
  if m.status <> 'active' then return m; end if;

  win := case when side = 'host' then 'guest' else 'host' end;
  perform finish_match(m.id, win, 'resign');

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
