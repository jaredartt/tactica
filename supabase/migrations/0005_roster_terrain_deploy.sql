-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. It is safe to run twice. It contains no DELETE, so the editor's
--  "Potential issue detected" dialog will not appear.
--  The last statement prints a row of checks. Every column must say true.
-- ===========================================================================
--  0005 — the real roster, terrain, and a deployment phase
--
--  This is the first migration that makes it a game rather than a skeleton.
--  Four things change, and they change together because they depend on
--  each other:
--
--    1. Six units with real stats, separate attack and counter reaches, rolled
--       damage, burn, and healing.
--    2. A 6x6 board with three destructible trees on each side, generated when
--       the room is opened.
--    3. Each player brings four of the six. No repeats.
--    4. Before turn one, both players arrange their four anywhere on their own
--       half.
--
--  COORDINATES. Canonically the guest holds rows 0..2 and the host rows 3..5,
--  so the host's screen is the canonical board. The guest's client rotates it
--  180 degrees so that every player looks at their own half from the bottom.
--  Nothing in the database knows about that; it is purely how it is drawn.
--
--  DISTANCE. Two different rules on purpose. Movement counts steps along the
--  grid and has to walk around trees, so range is a diamond and terrain
--  actually matters. Reach counts a diagonal as one, so attacks and counters
--  cover a square. Slow to close, wide to hit.
-- ===========================================================================

-- Old matches carry a v1 state the new client cannot read. Close them rather
-- than migrating a placeholder board nobody is attached to.
update public.matches set status = 'finished', turn_deadline = null
 where status in ('waiting', 'active');

alter table public.matches drop constraint if exists matches_status_check;
alter table public.matches add constraint matches_status_check
  check (status in ('waiting', 'deploying', 'active', 'finished'));

-- ---------------------------------------------------------------------------
-- 1. cards
--
-- attack/range on the old table were single numbers. A unit now needs a damage
-- BAND and two separate reaches, because "an archer is not countered unless
-- the thing it shot is also an archer" is not a rule about who is stronger --
-- it is a rule about who can reach back. Giving the counter its own range
-- makes that fall out on its own, with no special cases anywhere.
-- ---------------------------------------------------------------------------
alter table public.cards add column if not exists slug     text;
alter table public.cards add column if not exists mov      int  not null default 2;
alter table public.cards add column if not exists rmin     int  not null default 1;
alter table public.cards add column if not exists rmax     int  not null default 1;
-- crmin/crmax, not cmin/cmax: those two are Postgres system column names and
-- a table cannot have them.
alter table public.cards add column if not exists crmin    int  not null default 1;
alter table public.cards add column if not exists crmax     int  not null default 1;
alter table public.cards add column if not exists dmin     int  not null default 1;
alter table public.cards add column if not exists dmax     int  not null default 1;
alter table public.cards add column if not exists burns    boolean not null default false;
alter table public.cards add column if not exists heals    boolean not null default false;
alter table public.cards add column if not exists sort     int  not null default 0;

-- Plain, not partial: ON CONFLICT can only use a partial index if the insert
-- repeats its predicate, and a unique index already allows many NULLs.
drop index if exists public.cards_slug_key;
create unique index cards_slug_key on public.cards(slug);

-- The four placeholders from 0001 stay in the table but leave the roster.
-- (Retiring rather than deleting: no DELETE means no editor dialog, and a
-- finished match can still name the card it was fought with.)
update public.cards set is_active = false where slug is null;

insert into public.cards
  (slug, name, hp, mov, rmin, rmax, crmin, crmax, dmin, dmax, burns, heals,
   attack, move, range, ability, accent, sort, is_active)
values
  ('swordsman', 'Swordsman', 90, 2, 1, 1, 1, 1, 20, 30, false, false,
   25, 2, 1, 'Trades blow for blow at arm''s length.', '#2f4bff', 1, true),
  ('archer',    'Archer',    80, 2, 2, 2, 2, 2, 10, 20, false, false,
   15, 2, 2, 'Shoots at exactly two tiles, and is answered only by another archer.', '#f59e0b', 2, true),
  ('ninja',     'Ninja',     60, 3, 1, 1, 1, 1, 20, 30, false, false,
   25, 3, 1, 'Crosses three tiles a turn. Hits hard, folds fast.', '#0e0e14', 3, true),
  ('titan',     'Titan',    100, 1, 1, 1, 1, 1, 30, 40, false, false,
   35, 1, 1, 'One tile a turn, and the hardest hit on the board.', '#10b981', 4, true),
  ('mage',      'Mage',      70, 2, 2, 2, 1, 2, 15, 25, true,  false,
   20, 2, 2, 'Burns what it hits: a burned unit loses 5 HP whenever it strikes.', '#7c3aed', 5, true),
  ('healer',    'Healer',    80, 2, 1, 2, 1, 2,  5, 15, false, true,
   10, 2, 2, 'Hits at one or two tiles, or mends an ally for the same amount.', '#ec4899', 6, true)
on conflict (slug) do update set
  name = excluded.name, hp = excluded.hp, mov = excluded.mov,
  rmin = excluded.rmin, rmax = excluded.rmax,
  crmin = excluded.crmin, crmax = excluded.crmax,
  dmin = excluded.dmin, dmax = excluded.dmax,
  burns = excluded.burns, heals = excluded.heals,
  attack = excluded.attack, move = excluded.move, range = excluded.range,
  ability = excluded.ability, accent = excluded.accent,
  sort = excluded.sort, is_active = true, updated_at = now();

-- ---------------------------------------------------------------------------
-- 2. decks — four of the six, no repeats
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists deck text[];

create or replace function public.deck_size() returns int
language sql immutable as $$ select 4 $$;

create or replace function public.default_deck() returns text[]
language sql stable as $$
  select coalesce(array_agg(c.slug order by c.sort), '{}'::text[])
    from (select slug, sort from public.cards
           where is_active and slug is not null
           order by sort limit 4) c
$$;

create or replace function public.deck_of(p_user uuid) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare v_deck text[]; v_live int;
begin
  select deck into v_deck from public.profiles where id = p_user;
  if v_deck is null or array_length(v_deck, 1) <> deck_size() then
    return default_deck();
  end if;
  -- a card retired from the roster since they picked it invalidates the deck
  select count(*) into v_live from public.cards
   where is_active and slug = any(v_deck);
  if v_live <> deck_size() then return default_deck(); end if;
  return v_deck;
end $$;

create or replace function public.set_deck(p_deck text[])
returns text[] language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_n int;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if coalesce(array_length(p_deck, 1), 0) <> deck_size() then
    raise exception 'a deck is exactly % cards', deck_size();
  end if;
  select count(distinct s) into v_n from unnest(p_deck) s;
  if v_n <> deck_size() then raise exception 'no repeats in a deck'; end if;
  select count(*) into v_n from public.cards where is_active and slug = any(p_deck);
  if v_n <> deck_size() then raise exception 'that deck has a card that is not in the roster'; end if;

  update public.profiles set deck = p_deck where id = v_uid;
  return p_deck;
end $$;

-- ---------------------------------------------------------------------------
-- 3. geometry
--
-- All four of these are pure functions of a state blob. They are the single
-- definition of "can that unit stand there" and "can that unit see that" --
-- the client re-implements them to draw the highlights, but only these decide
-- anything.
-- ---------------------------------------------------------------------------
create or replace function public.cn_cheb(ax int, ay int, bx int, by int)
returns int language sql immutable as $$
  select greatest(abs(ax - bx), abs(ay - by))
$$;

-- Is a tree standing in the shot? A tree blocks if its centre lies within half
-- a tile of the straight line between the two units. That is the whole cover
-- rule: it holds for any reach, needs no special cases, and it is what a
-- player means when they say "I'm behind that tree".
create or replace function public.cn_los_clear(p_state jsonb, ax int, ay int, bx int, by int)
returns boolean language plpgsql immutable as $$
declare e jsonb; ox int; oy int; v_num float; v_den float;
begin
  v_den := sqrt((bx - ax)::float ^ 2 + (by - ay)::float ^ 2);
  if v_den = 0 then return true; end if;
  for e in select * from jsonb_array_elements(coalesce(p_state->'obstacles', '[]'::jsonb)) loop
    ox := (e->>'x')::int; oy := (e->>'y')::int;
    if (ox <> ax or oy <> ay) and (ox <> bx or oy <> by)
       and ox between least(ax, bx) and greatest(ax, bx)
       and oy between least(ay, by) and greatest(ay, by) then
      v_num := abs((bx - ax)::float * (ay - oy)::float
                 - (ax - ox)::float * (by - ay)::float);
      if v_num / v_den < 0.5 then return false; end if;
    end if;
  end loop;
  return true;
end $$;

-- Every tile a unit can walk to, as 'x,y' keys. A breadth-first walk of the
-- grid rather than a distance test, because a tree in the way has to make the
-- unit go around it -- otherwise terrain blocks shots but not feet, which
-- reads as a bug the first time someone walks through a trunk.
create or replace function public.cn_reach(p_state jsonb, p_x int, p_y int, p_mov int)
returns text[] language plpgsql immutable as $$
declare
  v_w int := (p_state->'board'->>'w')::int;
  v_h int := (p_state->'board'->>'h')::int;
  v_block boolean[]; v_seen boolean[]; v_front int[]; v_next int[];
  e jsonb; i int; j int; k int; v_step int;
  v_x int; v_y int; nx int; ny int;
  v_dx int[] := array[1, -1, 0, 0];
  v_dy int[] := array[0, 0, 1, -1];
  v_out text[] := '{}';
begin
  v_block := array_fill(false, array[v_w * v_h]);
  v_seen  := array_fill(false, array[v_w * v_h]);
  for e in select * from jsonb_array_elements(p_state->'units') loop
    v_block[(e->>'y')::int * v_w + (e->>'x')::int + 1] := true;
  end loop;
  for e in select * from jsonb_array_elements(coalesce(p_state->'obstacles', '[]'::jsonb)) loop
    v_block[(e->>'y')::int * v_w + (e->>'x')::int + 1] := true;
  end loop;

  i := p_y * v_w + p_x + 1;
  v_seen[i] := true;
  v_front := array[i];

  for v_step in 1..greatest(p_mov, 0) loop
    v_next := '{}'::int[];
    foreach i in array v_front loop
      v_x := (i - 1) % v_w; v_y := (i - 1) / v_w;
      for k in 1..4 loop
        nx := v_x + v_dx[k]; ny := v_y + v_dy[k];
        if nx >= 0 and ny >= 0 and nx < v_w and ny < v_h then
          j := ny * v_w + nx + 1;
          if not v_seen[j] and not v_block[j] then
            v_seen[j] := true;
            v_next := v_next || j;
            v_out  := v_out || (nx || ',' || ny);
          end if;
        end if;
      end loop;
    end loop;
    v_front := v_next;
    exit when coalesce(array_length(v_front, 1), 0) = 0;
  end loop;
  return v_out;
end $$;

-- Whose half is that row? The host defends the bottom of the canonical board.
create or replace function public.cn_own_half(p_side text, p_y int, p_h int)
returns boolean language sql immutable as $$
  select case when p_side = 'host' then p_y >= p_h / 2 else p_y < p_h / 2 end
$$;

-- ---------------------------------------------------------------------------
-- 4. the map
--
-- Three trees per half, drawn when the room is opened. Never in a corner --
-- a corner tree blocks nothing anybody wanted to walk through -- and never
-- within one tile of another, so they read as three separate pieces of cover
-- instead of one wall. The two halves are rolled independently, which means
-- the terrain is NOT mirrored; if that turns out to matter competitively,
-- generating one half and reflecting it is a four-line change here and
-- nothing else in the system needs to know.
-- ---------------------------------------------------------------------------
create or replace function public.cn_gen_trees(p_w int, p_h int)
returns jsonb language plpgsql as $$
declare
  v_try int; v_band int; v_lo int; v_hi int; v_n int;
  v_cand int[]; v_pick int[] := '{}'::int[]; v_ok boolean;
  i int; j int; v_x int; v_y int; v_px int; v_py int;
  v_out jsonb := '[]'::jsonb; v_k int := 0;
begin
  for v_try in 1..80 loop
    v_pick := '{}'::int[];
    for v_band in 0..1 loop
      if v_band = 0 then v_lo := 0; v_hi := p_h / 2 - 1;
                    else v_lo := p_h / 2; v_hi := p_h - 1; end if;

      select array_agg(t) into v_cand from (
        select gy.y * p_w + gx.x as t
          from generate_series(0, p_w - 1) as gx(x),
               generate_series(v_lo, v_hi) as gy(y)
         where not ((gx.x = 0 or gx.x = p_w - 1) and (gy.y = 0 or gy.y = p_h - 1))
         order by random()) s;

      v_n := 0;
      foreach i in array v_cand loop
        exit when v_n = 3;
        v_x := i % p_w; v_y := i / p_w;
        v_ok := true;
        foreach j in array v_pick loop
          v_px := j % p_w; v_py := j / p_w;
          if cn_cheb(v_x, v_y, v_px, v_py) < 2 then v_ok := false; exit; end if;
        end loop;
        if v_ok then v_pick := v_pick || i; v_n := v_n + 1; end if;
      end loop;
      exit when v_n < 3;
    end loop;
    exit when coalesce(array_length(v_pick, 1), 0) = 6;
  end loop;

  -- A shuffled greedy pass can in principle paint itself into a corner. It
  -- has eighty goes; if every one of them failed, use a layout that is known
  -- to satisfy the rules rather than opening a room with no trees in it.
  if coalesce(array_length(v_pick, 1), 0) <> 6 then
    v_pick := array[ 1, 4, 1 * p_w + 2,
                     (p_h - 1) * p_w + 1, (p_h - 1) * p_w + 4, (p_h - 2) * p_w + 2 ];
  end if;

  foreach i in array v_pick loop
    v_k := v_k + 1;
    v_out := v_out || jsonb_build_object(
      'id', 't' || v_k, 'x', i % p_w, 'y', i / p_w, 'hp', 30, 'maxHp', 30);
  end loop;
  return v_out;
end $$;

create or replace function public.cn_fresh_map()
returns jsonb language plpgsql as $$
declare v_w int := 6; v_h int := 6;
begin
  return jsonb_build_object(
    'v', 2,
    'board', jsonb_build_object('w', v_w, 'h', v_h),
    'phase', 'deploy',
    'ready', jsonb_build_object('host', false, 'guest', false),
    'obstacles', cn_gen_trees(v_w, v_h),
    'units', '[]'::jsonb,
    'turn', 'host',
    'turnNumber', 0,
    'log', '[]'::jsonb,
    'winner', null);
end $$;

-- Put one player's four cards on their own half in a default formation. They
-- start somewhere legal and then rearrange -- which is much simpler than a
-- reserve the units have to be dragged out of, and it means a player who
-- never touches the deploy screen still fields an army.
create or replace function public.cn_place(p_state jsonb, p_side text, p_deck text[])
returns jsonb language plpgsql as $$
declare
  v_w int := (p_state->'board'->>'w')::int;
  v_h int := (p_state->'board'->>'h')::int;
  v_taken text[] := '{}'; e jsonb; c public.cards;
  v_xs int[] := '{}'::int[]; v_ys int[] := '{}'::int[];
  i int; vx int; vy int; v_slot int := 0; v_idx int := 0;
  v_units jsonb := p_state->'units'; v_done boolean;
begin
  for e in select * from jsonb_array_elements(v_units) loop
    v_taken := v_taken || ((e->>'x') || ',' || (e->>'y'));
  end loop;
  for e in select * from jsonb_array_elements(coalesce(p_state->'obstacles', '[]'::jsonb)) loop
    v_taken := v_taken || ((e->>'x') || ',' || (e->>'y'));
  end loop;

  -- Odd columns first, so four units land spread out rather than in a block.
  for i in 0 .. (v_w - 1) / 2 loop
    if 2 * i + 1 < v_w then v_xs := v_xs || (2 * i + 1); end if;
  end loop;
  for i in 0 .. (v_w - 1) / 2 loop
    if 2 * i < v_w then v_xs := v_xs || (2 * i); end if;
  end loop;

  if p_side = 'host'
    then for i in reverse (v_h - 1) .. (v_h / 2) loop v_ys := v_ys || i; end loop;
    else for i in 0 .. (v_h / 2 - 1)            loop v_ys := v_ys || i; end loop;
  end if;

  for i in 1 .. deck_size() loop
    select * into c from public.cards where slug = p_deck[i];
    if c.id is null then raise exception 'unknown card %', p_deck[i]; end if;

    v_done := false;
    foreach vy in array v_ys loop
      foreach vx in array v_xs loop
        if not ((vx || ',' || vy) = any(v_taken)) then
          v_taken := v_taken || (vx || ',' || vy);
          v_done := true;
          exit;
        end if;
      end loop;
      -- tested AFTER the row, not before it: testing first would let the
      -- outer loop advance vy once more and place the unit a row off.
      exit when v_done;
    end loop;
    if not v_done then raise exception 'nowhere to deploy'; end if;

    v_idx := v_idx + 1;
    v_units := v_units || jsonb_build_object(
      'id', substr(p_side, 1, 1) || v_idx, 'owner', p_side,
      'cardId', c.id, 'slug', c.slug, 'name', c.name,
      'hp', c.hp, 'maxHp', c.hp, 'mov', c.mov,
      'rmin', c.rmin, 'rmax', c.rmax, 'crmin', c.crmin, 'crmax', c.crmax,
      'dmin', c.dmin, 'dmax', c.dmax,
      'burns', c.burns, 'heals', c.heals, 'burned', false,
      'accent', c.accent, 'art', c.art_url, 'ability', c.ability,
      'x', vx, 'y', vy, 'moved', false, 'acted', false);
  end loop;

  return jsonb_set(p_state, '{units}', v_units);
end $$;

-- ---------------------------------------------------------------------------
-- 5. opening and joining a room
-- ---------------------------------------------------------------------------
create or replace function public.create_match()
returns public.matches
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_name text; v_st jsonb; m public.matches;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username into v_name from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;

  v_st := state_log(cn_fresh_map(), v_name || ' opened the arena.');

  insert into public.matches (code, host_id, host_name, state)
  values (gen_match_code(), v_uid, v_name, v_st)
  returning * into m;

  insert into public.match_presence (match_id, user_id, side)
  values (m.id, v_uid, 'host') on conflict (match_id, user_id) do update set seen_at = now();
  return m;
end $$;

create or replace function public.join_match(p_code text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_name text; m public.matches; v_st jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username into v_name from public.profiles where id = v_uid;

  select * into m from public.matches where code = upper(trim(p_code)) for update;
  if m.id is null then raise exception 'no room with that code'; end if;
  if m.host_id = v_uid or m.guest_id = v_uid then return m; end if;
  if m.status <> 'waiting' then raise exception 'that room is already full'; end if;

  -- Both armies exist from this moment. Deployment only moves them.
  v_st := cn_place(m.state, 'host',  deck_of(m.host_id));
  v_st := cn_place(v_st,    'guest', deck_of(v_uid));
  v_st := state_log(v_st, v_name || ' entered the arena.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  update public.matches
     set guest_id = v_uid, guest_name = v_name, status = 'deploying',
         state = v_st, turn_deadline = now() + interval '90 seconds',
         updated_at = now()
   where id = m.id returning * into m;

  insert into public.match_presence (match_id, user_id, side)
  values (m.id, v_uid, 'guest') on conflict (match_id, user_id) do update set seen_at = now();
  return m;
end $$;

-- ---------------------------------------------------------------------------
-- 6. deployment
-- ---------------------------------------------------------------------------
create or replace function public.deploy_unit(p_match uuid, p_unit text, p_x int, p_y int)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; v_side text; v_st jsonb; u jsonb;
  v_me jsonb; v_swap jsonb; v_out jsonb := '[]'::jsonb;
  v_w int; v_h int; e jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'deploying' then raise exception 'deployment is over'; end if;

  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if (m.state->'ready'->>v_side)::boolean then raise exception 'you are already ready'; end if;

  v_st := m.state;
  v_w := (v_st->'board'->>'w')::int;
  v_h := (v_st->'board'->>'h')::int;

  -- Whose unit it is comes first, then where it is going. Ordered that way so
  -- the error you get names the thing you actually got wrong.
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
    if (u->>'x')::int = p_x and (u->>'y')::int = p_y then v_swap := u; end if;
  end loop;

  if v_me is null then raise exception 'no such unit'; end if;
  if v_me->>'owner' <> v_side then raise exception 'that is not your unit'; end if;

  if p_x < 0 or p_y < 0 or p_x >= v_w or p_y >= v_h then raise exception 'off the board'; end if;
  if not cn_own_half(v_side, p_y, v_h) then raise exception 'that is not your half'; end if;

  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if (e->>'x')::int = p_x and (e->>'y')::int = p_y then
      raise exception 'there is a tree there';
    end if;
  end loop;

  -- Landing on one of your own is a swap, not an error: it is the fastest way
  -- to say "these two the other way round".
  if v_swap is not null and v_swap->>'owner' <> v_side then
    raise exception 'that tile is occupied';
  end if;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      u := jsonb_set(jsonb_set(u, '{x}', to_jsonb(p_x)), '{y}', to_jsonb(p_y));
    elsif v_swap is not null and u->>'id' = v_swap->>'id' then
      u := jsonb_set(jsonb_set(u, '{x}', v_me->'x'), '{y}', v_me->'y');
    end if;
    v_out := v_out || u;
  end loop;

  update public.matches set state = jsonb_set(v_st, '{units}', v_out), updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

-- Marks you ready; the second flag starts the match. Called by force_timeout
-- with p_force so a player who wandered off does not hold the room forever.
create or replace function public.cn_set_ready(p_match uuid, p_side text, p_force boolean)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare m public.matches; v_st jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  if m.status <> 'deploying' then return m; end if;

  v_st := m.state;
  if p_force then
    v_st := jsonb_set(v_st, '{ready}', jsonb_build_object('host', true, 'guest', true));
    v_st := state_log(v_st, 'Deployment time ran out.');
  else
    v_st := jsonb_set(v_st, array['ready', p_side], 'true'::jsonb);
    v_st := state_log(v_st,
      case when p_side = 'host' then m.host_name else m.guest_name end || ' is ready.');
  end if;

  if not ((v_st->'ready'->>'host')::boolean and (v_st->'ready'->>'guest')::boolean) then
    update public.matches set state = v_st, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  v_st := jsonb_set(v_st, '{phase}', '"battle"'::jsonb);
  v_st := jsonb_set(v_st, '{turnNumber}', '1'::jsonb);
  v_st := state_log(v_st, 'Turn 1 — ' || m.host_name || ' to act.');

  update public.matches
     set state = v_st, status = 'active',
         turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

create or replace function public.set_ready(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare m public.matches; v_side text;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'deploying' then raise exception 'deployment is over'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  return cn_set_ready(p_match, v_side, false);
end $$;

-- ---------------------------------------------------------------------------
-- 7. the turn
-- ---------------------------------------------------------------------------
create or replace function public.cn_roll(p_lo int, p_hi int)
returns int language sql volatile as $$
  select p_lo + floor(random() * (p_hi - p_lo + 1))::int
$$;

create or replace function public.submit_move(p_match uuid, p_unit text, p_x int, p_y int)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; v_side text; v_st jsonb; u jsonb;
  v_me jsonb; v_out jsonb := '[]'::jsonb; v_reach text[];
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;

  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.state->>'turn' <> v_side then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then raise exception 'your time ran out'; end if;

  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if v_me->>'owner' <> v_side then raise exception 'that is not your unit'; end if;
  if (v_me->>'moved')::boolean then raise exception 'that unit already moved'; end if;

  v_reach := cn_reach(v_st, (v_me->>'x')::int, (v_me->>'y')::int, (v_me->>'mov')::int);
  if not ((p_x || ',' || p_y) = any(v_reach)) then
    raise exception 'that unit cannot reach that tile';
  end if;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      u := jsonb_set(jsonb_set(u, '{x}', to_jsonb(p_x)), '{y}', to_jsonb(p_y));
      u := jsonb_set(u, '{moved}', 'true'::jsonb);
    end if;
    v_out := v_out || u;
  end loop;

  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := state_log(v_st, (v_me->>'name') || ' advances.');
  update public.matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

-- ---------------------------------------------------------------------------
-- submit_attack — one function, four outcomes
--
-- A counter happens when the ATTACKER stands inside the DEFENDER's counter
-- reach. Nothing compares the two units' strength, and there is no clause
-- anywhere about archers: an archer shoots at exactly two, a swordsman answers
-- at exactly one, so the swordsman simply cannot reach back -- while a second
-- archer, whose counter reach is also exactly two, can. The rule falls out of
-- the numbers, which is why every future unit gets it for free.
--
-- The same tree that stops the shot stops the answer, because the line is the
-- same line. Burn lands at the END of the exchange, so the unit you just set
-- alight is not taxed for the counter it makes in that same breath -- it pays
-- from its next swing onwards, which is what a player expects to see.
-- ---------------------------------------------------------------------------
create or replace function public.submit_attack(p_match uuid, p_unit text, p_target text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; v_side text; v_other text; v_st jsonb; u jsonb; e jsonb;
  v_atk jsonb; v_tgt jsonb; v_tree jsonb;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_dist int; v_dmg int := 0; v_heal int := 0;
  v_tgt_hp int; v_atk_hp int; v_counter int := 0;
  v_burn_atk int := 0; v_burn_tgt int := 0; v_new_burn boolean := false;
  v_killed_tgt boolean := false; v_killed_atk boolean := false;
  v_ally boolean := false; v_foes int := 0; v_mine int := 0; v_win text;
  v_note text;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;

  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  v_other := case when v_side = 'host' then 'guest' else 'host' end;
  if m.state->>'turn' <> v_side then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then raise exception 'your time ran out'; end if;

  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit   then v_atk := u; end if;
    if u->>'id' = p_target then v_tgt := u; end if;
  end loop;
  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if e->>'id' = p_target then v_tree := e; end if;
  end loop;

  if v_atk is null then raise exception 'no such unit'; end if;
  if v_tgt is null and v_tree is null then raise exception 'no such target'; end if;
  if v_atk->>'owner' <> v_side then raise exception 'that is not your unit'; end if;
  if (v_atk->>'acted')::boolean then raise exception 'that unit already acted'; end if;

  if v_tree is not null then
    v_dist := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                      (v_tree->>'x')::int, (v_tree->>'y')::int);
  else
    v_ally := (v_tgt->>'owner' = v_side);
    if v_ally and not (v_atk->>'heals')::boolean then raise exception 'no friendly fire'; end if;
    v_dist := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                      (v_tgt->>'x')::int, (v_tgt->>'y')::int);
  end if;

  if v_dist < (v_atk->>'rmin')::int then raise exception 'too close for that unit'; end if;
  if v_dist > (v_atk->>'rmax')::int then raise exception 'out of range'; end if;
  if not cn_los_clear(v_st, (v_atk->>'x')::int, (v_atk->>'y')::int,
                      coalesce((v_tgt->>'x')::int, (v_tree->>'x')::int),
                      coalesce((v_tgt->>'y')::int, (v_tree->>'y')::int)) then
    raise exception 'a tree is in the way';
  end if;

  v_atk_hp := (v_atk->>'hp')::int;

  -- ---- mending an ally --------------------------------------------------
  if v_ally then
    v_heal := cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int);
    v_tgt_hp := least((v_tgt->>'maxHp')::int, (v_tgt->>'hp')::int + v_heal);
    v_heal := v_tgt_hp - (v_tgt->>'hp')::int;
    v_note := (v_atk->>'name') || ' mends ' || (v_tgt->>'name') || ' for ' || v_heal || '.';

  -- ---- chopping a tree --------------------------------------------------
  elsif v_tree is not null then
    v_dmg := cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int);
    v_tgt_hp := (v_tree->>'hp')::int - v_dmg;
    v_killed_tgt := v_tgt_hp <= 0;
    if (v_atk->>'burned')::boolean then
      v_burn_atk := 5; v_atk_hp := v_atk_hp - 5;
    end if;
    v_killed_atk := v_atk_hp <= 0;
    v_note := (v_atk->>'name') || ' strikes a tree for ' || v_dmg
              || case when v_killed_tgt then ' -- it falls.' else '.' end;

  -- ---- a real exchange ---------------------------------------------------
  else
    v_dmg := cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int);
    v_tgt_hp := (v_tgt->>'hp')::int - v_dmg;
    v_killed_tgt := v_tgt_hp <= 0;

    if not v_killed_tgt
       and v_dist >= (v_tgt->>'crmin')::int
       and v_dist <= (v_tgt->>'crmax')::int then
      v_counter := cn_roll((v_tgt->>'dmin')::int, (v_tgt->>'dmax')::int);
      v_atk_hp := v_atk_hp - v_counter;
      if (v_tgt->>'burned')::boolean then
        v_burn_tgt := 5;
        v_tgt_hp := v_tgt_hp - 5;
        v_killed_tgt := v_tgt_hp <= 0;
      end if;
    end if;

    if (v_atk->>'burned')::boolean then
      v_burn_atk := 5; v_atk_hp := v_atk_hp - 5;
    end if;
    v_killed_atk := v_atk_hp <= 0;
    v_new_burn := (v_atk->>'burns')::boolean and not v_killed_tgt;

    v_note := (v_atk->>'name') || ' hits ' || (v_tgt->>'name') || ' for ' || v_dmg
              || case when v_killed_tgt and v_burn_tgt = 0 then ' -- destroyed.' else '.' end;
  end if;

  -- ---- write it back -----------------------------------------------------
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      if not v_killed_atk then
        u := jsonb_set(u, '{acted}', 'true'::jsonb);
        u := jsonb_set(u, '{moved}', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb(v_atk_hp));
        v_out := v_out || u;
      end if;
    elsif v_tree is null and u->>'id' = p_target then
      if v_ally then
        v_out := v_out || jsonb_set(u, '{hp}', to_jsonb(v_tgt_hp));
      elsif not v_killed_tgt then
        u := jsonb_set(u, '{hp}', to_jsonb(v_tgt_hp));
        if v_new_burn then u := jsonb_set(u, '{burned}', 'true'::jsonb); end if;
        v_out := v_out || u;
      end if;
    else
      v_out := v_out || u;
    end if;
  end loop;

  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if v_tree is not null and e->>'id' = p_target then
      if not v_killed_tgt then v_rocks := v_rocks || jsonb_set(e, '{hp}', to_jsonb(v_tgt_hp)); end if;
    else
      v_rocks := v_rocks || e;
    end if;
  end loop;

  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
  v_st := jsonb_set(v_st, '{fx}', jsonb_build_object(
    'seq', coalesce((v_st->'fx'->>'seq')::int, 0) + 1,
    'atk', p_unit, 'tgt', p_target,
    'dmg', v_dmg, 'heal', v_heal,
    'killedTgt', v_killed_tgt, 'counter', v_counter, 'killedAtk', v_killed_atk,
    'burnAtk', v_burn_atk, 'burnTgt', v_burn_tgt, 'newBurn', v_new_burn,
    'tree', (v_tree is not null)));

  v_st := state_log(v_st, v_note);
  if v_new_burn then
    v_st := state_log(v_st, (v_tgt->>'name') || ' is burning.');
  end if;
  if v_counter > 0 then
    v_st := state_log(v_st, (v_tgt->>'name') || ' counters for ' || v_counter
      || case when v_killed_atk and v_burn_atk = 0 then ' -- ' || (v_atk->>'name') || ' destroyed.'
              else '.' end);
  end if;
  if v_burn_tgt > 0 then
    v_st := state_log(v_st, (v_tgt->>'name') || ' burns for ' || v_burn_tgt
      || case when v_killed_tgt then ' -- destroyed.' else '.' end);
  end if;
  if v_burn_atk > 0 then
    v_st := state_log(v_st, (v_atk->>'name') || ' burns for ' || v_burn_atk
      || case when v_killed_atk then ' -- destroyed.' else '.' end);
  end if;

  for u in select * from jsonb_array_elements(v_out) loop
    if u->>'owner' = v_side then v_mine := v_mine + 1; else v_foes := v_foes + 1; end if;
  end loop;
  if v_foes = 0 then v_win := v_side;
  elsif v_mine = 0 then v_win := v_other; end if;

  if v_win is not null then
    perform finish_match(m.id, v_win, 'defeat');
    v_st := jsonb_set(v_st, '{winner}', to_jsonb(v_win));
    v_st := state_log(v_st,
      case when v_win = 'host' then m.host_name else m.guest_name end || ' wins.');
    update public.matches
       set state = v_st, status = 'finished', winner = v_win,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
  else
    update public.matches set state = v_st, updated_at = now()
     where id = m.id returning * into m;
  end if;
  return m;
end $$;

-- ---------------------------------------------------------------------------
-- 8. the clock — now covers deployment too
-- ---------------------------------------------------------------------------
create or replace function public.force_timeout(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare m public.matches; v_loser text;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.turn_deadline is null then return m; end if;
  if now() <= m.turn_deadline + interval '2 seconds' then return m; end if;

  if m.status = 'deploying' then return cn_set_ready(p_match, null, true); end if;
  if m.status <> 'active' then return m; end if;

  v_loser := case when m.state->>'turn' = 'host' then m.host_name else m.guest_name end;
  return advance_turn(p_match, v_loser || ' ran out of time.');
end $$;

-- A player who walks out of the deploy screen concedes, the same as one who
-- walks out mid-battle. Without this a half-set-up room could only end by
-- someone sitting through the clock.
create or replace function public.resign_match(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare m public.matches; v_side text; v_win text; v_st jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.status not in ('active', 'deploying') then return m; end if;

  v_win := case when v_side = 'host' then 'guest' else 'host' end;
  perform finish_match(m.id, v_win, 'resign');

  v_st := state_log(m.state,
        case when v_side = 'host' then m.host_name else m.guest_name end
        || ' resigned. '
        || case when v_win = 'host' then m.host_name else m.guest_name end || ' wins.');
  v_st := jsonb_set(v_st, '{winner}', to_jsonb(v_win));

  update public.matches
     set state = v_st, status = 'finished', winner = v_win,
         turn_deadline = null, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

-- ---------------------------------------------------------------------------
-- 9. rematch — a NEW map, and both decks re-read, so a deck changed between
--    games takes effect immediately.
-- ---------------------------------------------------------------------------
create or replace function public.request_rematch(p_match uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare m public.matches; v_side text; v_st jsonb; nm public.matches;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'finished' then raise exception 'that match is still running'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.next_match_id is not null then return m.next_match_id; end if;

  if v_side = 'host'
    then update public.matches set rematch_host  = true where id = p_match;
    else update public.matches set rematch_guest = true where id = p_match;
  end if;

  select * into m from public.matches where id = p_match;
  if not (m.rematch_host and m.rematch_guest) then return null; end if;

  -- Sides swap, so nobody keeps the first-move advantage two games running.
  v_st := cn_fresh_map();
  v_st := cn_place(v_st, 'host',  deck_of(m.guest_id));
  v_st := cn_place(v_st, 'guest', deck_of(m.host_id));
  v_st := state_log(v_st, 'Rematch on new ground. ' || m.guest_name || ' moves first.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline)
  values
    (gen_match_code(), m.guest_id, m.guest_name, m.host_id, m.host_name,
     'deploying', v_st, now() + interval '90 seconds')
  returning * into nm;

  insert into public.match_presence (match_id, user_id, side) values
    (nm.id, nm.host_id, 'host'), (nm.id, nm.guest_id, 'guest')
  on conflict (match_id, user_id) do update set seen_at = now();

  update public.matches set next_match_id = nm.id where id = p_match;
  return nm.id;
end $$;

-- ---------------------------------------------------------------------------
-- 10. grants
-- ---------------------------------------------------------------------------
revoke execute on function public.cn_set_ready(uuid, text, boolean) from public, anon, authenticated;
revoke execute on function public.cn_place(jsonb, text, text[])     from public, anon, authenticated;
revoke execute on function public.cn_fresh_map()                    from public, anon, authenticated;
revoke execute on function public.cn_gen_trees(int, int)            from public, anon, authenticated;
revoke execute on function public.deck_of(uuid)                     from public, anon, authenticated;
grant  execute on function public.set_deck(text[])                  to authenticated;
grant  execute on function public.deploy_unit(uuid, text, int, int) to authenticated;
grant  execute on function public.set_ready(uuid)                   to authenticated;
grant  execute on function public.default_deck()                    to authenticated;
grant  execute on function public.deck_size()                       to authenticated;
grant  execute on function public.cn_cheb(int, int, int, int)       to authenticated;
grant  execute on function public.cn_reach(jsonb, int, int, int)    to authenticated;
grant  execute on function public.cn_los_clear(jsonb, int, int, int, int) to authenticated;
grant  execute on function public.cn_own_half(text, int, int)       to authenticated;
grant  execute on function public.cn_roll(int, int)                 to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.cards where is_active and slug is not null) = 6 as roster_is_six,
  to_regprocedure('public.set_deck(text[])')                is not null as decks_ready,
  to_regprocedure('public.deploy_unit(uuid,text,int,int)')  is not null as deploy_ready,
  to_regprocedure('public.set_ready(uuid)')                 is not null as ready_button_ready,
  jsonb_array_length(public.cn_gen_trees(6, 6)) = 6         as map_makes_six_trees;
