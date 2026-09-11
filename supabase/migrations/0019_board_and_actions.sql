-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0018 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0019 - the board stands up, and a turn becomes two goes
--
--  Two changes that have to travel together, because each one is unplayable
--  without the other.
--
--  The board turns back. 0011 made the halves left and right so both players
--  would see the same picture; that worked, and it is also why a knight's
--  advance now reads sideways. The halves become top and bottom again -- but
--  this time nothing is rotated in the database. The board is 8 tall and 6
--  wide, the host holds rows 0-3 and the guest rows 4-7, and the CLIENT flips
--  it per player so you are always at the bottom looking up, chess.com style.
--  The server keeps one set of coordinates; only the drawing changes. That is
--  what 0011 actually bought, and it survives.
--
--  And a turn stops being "everybody does everything". Until now all five of
--  your units could move and strike every turn, which is not a tactics game so
--  much as a race. A turn is now TWO activations. One activation is one unit's
--  whole go -- move, then strike, or just one of the two -- and each unit gets
--  at most one per turn, so a turn is two different units doing something
--  real. The player who opens the match gets one activation instead of two,
--  because going first with a full turn is worth too much on a board this size.
--
--  Defend arrives with them: it costs an activation and halves what lands on
--  that unit until its next turn. The hook was already in cn_damage (0018);
--  this is the first thing to pass it anything but false.
--
--  Three of the functions below -- cn_move, cn_attack, advance_turn -- are the
--  0018 definitions with the new lines spliced in, not rewritten. deploy_unit
--  lost its swap behaviour once by being reconstructed from memory; that is
--  not happening twice.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. whose ground is that row
--
-- Dropped rather than replaced, for the same reason 0011 dropped cn_own_half:
-- the arguments now mean y and h where they meant x and w, and Postgres will
-- not let a replacement rename an input parameter. A function whose parameter
-- is called p_x while holding a y is worse than a drop.
-- ---------------------------------------------------------------------------
drop function if exists public.cn_own_side(text, int, int);

create or replace function public.cn_own_side(p_side text, p_y int, p_h int)
returns boolean language sql immutable as $$
  select case when p_side = 'host' then p_y < p_h / 2 else p_y >= p_h / 2 end
$$;
grant execute on function public.cn_own_side(text, int, int) to authenticated, anon;

-- ---------------------------------------------------------------------------
-- 2. deployment checks the row
-- ---------------------------------------------------------------------------
create or replace function public.deploy_unit(p_match uuid, p_unit text, p_x integer, p_y integer)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; v_side text; v_st jsonb; v_units jsonb; u jsonb; e jsonb;
  v_me jsonb; v_swap jsonb; v_out jsonb := '[]'::jsonb; v_w int; v_h int;
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

  select units into v_units from public.match_deploy
   where match_id = p_match and side = v_side for update;
  if v_units is null then raise exception 'nothing to deploy'; end if;

  for u in select * from jsonb_array_elements(v_units) loop
    if u->>'id' = p_unit then v_me := u; end if;
    if (u->>'x')::int = p_x and (u->>'y')::int = p_y then v_swap := u; end if;
  end loop;
  if v_me is null then raise exception 'that is not your unit'; end if;

  if p_x < 0 or p_y < 0 or p_x >= v_w or p_y >= v_h then raise exception 'off the board'; end if;
  if not cn_own_side(v_side, p_y, v_h) then raise exception 'that is not your half'; end if;

  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if (e->>'x')::int = p_x and (e->>'y')::int = p_y then
      raise exception 'there is a tree there';
    end if;
  end loop;

  -- Landing on one of your own is a swap, not an error: it is the fastest way
  -- to say "these two the other way round". The other army is not in this
  -- array at all, so there is nothing else it could collide with.
  for u in select * from jsonb_array_elements(v_units) loop
    if u->>'id' = p_unit then
      u := jsonb_set(jsonb_set(u, '{x}', to_jsonb(p_x)), '{y}', to_jsonb(p_y));
    elsif v_swap is not null and u->>'id' = v_swap->>'id' then
      u := jsonb_set(jsonb_set(u, '{x}', v_me->'x'), '{y}', v_me->'y');
    end if;
    v_out := v_out || u;
  end loop;

  update public.match_deploy set units = v_out
   where match_id = p_match and side = v_side;
  update public.matches set updated_at = now() where id = p_match;
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- 3. the opening formation, and the trees
-- ---------------------------------------------------------------------------
create or replace function public.cn_army(p_state jsonb, p_side text, p_deck text[])
returns jsonb
language plpgsql as $$
declare
  v_w int := (p_state->'board'->>'w')::int;
  v_h int := (p_state->'board'->>'h')::int;
  v_taken text[] := '{}'; e jsonb; c public.cards;
  v_xs int[] := '{}'::int[]; v_ys int[] := '{}'::int[];
  i int; vx int; vy int; v_idx int := 0;
  v_units jsonb := '[]'::jsonb; v_done boolean;
begin
  for e in select * from jsonb_array_elements(coalesce(p_state->'obstacles', '[]'::jsonb)) loop
    v_taken := v_taken || ((e->>'x') || ',' || (e->>'y'));
  end loop;

  -- columns, odd ones first, so five units on a six-wide board do not end
  -- up shoulder to shoulder along the back rank
  for i in 0 .. (v_w - 1) / 2 loop
    if 2 * i + 1 < v_w then v_xs := v_xs || (2 * i + 1); end if;
  end loop;
  for i in 0 .. (v_w - 1) / 2 loop
    if 2 * i < v_w then v_xs := v_xs || (2 * i); end if;
  end loop;

  -- rows, back rank first. The host's home row is 0, the guest's is h-1,
  -- so the two armies start facing each other down the long axis.
  if p_side = 'host'
    then for i in 0 .. (v_h / 2 - 1)            loop v_ys := v_ys || i; end loop;
    else for i in reverse (v_h - 1) .. (v_h / 2) loop v_ys := v_ys || i; end loop;
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
      exit when v_done;
    end loop;
    if not v_done then raise exception 'nowhere to deploy'; end if;

    v_idx := v_idx + 1;
    v_units := v_units || jsonb_build_object(
      'id', substr(p_side, 1, 1) || v_idx, 'owner', p_side,
      'cardId', c.id, 'slug', c.slug, 'name', c.name, 'role', c.role,
      'hp', c.hp, 'maxHp', c.hp, 'mov', c.mov,
      'rmin', c.rmin, 'rmax', c.rmax, 'crmin', c.crmin, 'crmax', c.crmax,
      'dmin', c.dmin, 'dmax', c.dmax, 'pow', c.power,
      'parryPct', c.parry_pct, 'critPct', c.crit_pct, 'parryAll', c.parry_all,
      'royal', c.royal,
      'burns', c.burns, 'heals', c.heals, 'burned', false,
      'flies', c.flies, 'sneaks', c.sneaks, 'cures', c.cures, 'tramples', c.tramples,
      'parries', c.parries, 'blooms', c.blooms,
      'accent', c.accent, 'art', c.art_url, 'ability', c.ability,
      'x', vx, 'y', vy, 'moved', false, 'acted', false);
  end loop;
  return v_units;
end
$$;

create or replace function public.cn_gen_trees(p_w integer, p_h integer)
returns jsonb
language plpgsql as $$
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

      -- Nothing in the row nearest either player's edge. That row is where
      -- the army stands up, and a tree in it costs somebody a starting
      -- square. The rule swallows the old no-corners one -- every corner
      -- sits in a home row -- so the corner clause below is now redundant
      -- and kept only so the intent survives a change to the board shape.
      select array_agg(t) into v_cand from (
        select gy.y * p_w + gx.x as t
          from generate_series(0, p_w - 1) as gx(x),
               generate_series(v_lo, v_hi) as gy(y)
         where gy.y <> 0 and gy.y <> p_h - 1
           and not ((gx.x = 0 or gx.x = p_w - 1) and (gy.y = 0 or gy.y = p_h - 1))
         order by random()) s;

      v_n := 0;
      foreach i in array v_cand loop
        exit when v_n = 4;
        v_x := i % p_w; v_y := i / p_w;
        v_ok := true;
        foreach j in array v_pick loop
          v_px := j % p_w; v_py := j / p_w;
          if cn_cheb(v_x, v_y, v_px, v_py) < 2 then v_ok := false; exit; end if;
        end loop;
        if v_ok then v_pick := v_pick || i; v_n := v_n + 1; end if;
      end loop;
      exit when v_n < 4;
    end loop;
    exit when coalesce(array_length(v_pick, 1), 0) = 8;
  end loop;

  -- Eighty shuffled goes is plenty, but a greedy pass can in principle paint
  -- itself into a corner. If every one failed, use a layout known to satisfy
  -- the rules rather than opening a room with no trees in it: one tree per
  -- half-column, staggered down the rows.
  if coalesce(array_length(v_pick, 1), 0) <> 8 then
    v_pick := array[ 1 * p_w + 0, 1 * p_w + 2, 1 * p_w + 4,
                     (p_h / 2 - 1) * p_w + 1,
                     (p_h - 2) * p_w + 1, (p_h - 2) * p_w + 3,
                     (p_h - 2) * p_w + 5, (p_h / 2) * p_w + 4 ];
  end if;

  foreach i in array v_pick loop
    v_k := v_k + 1;
    v_out := v_out || jsonb_build_object(
      'id', 't' || v_k, 'x', i % p_w, 'y', i / p_w, 'hp', 30, 'maxHp', 30);
  end loop;
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- 4. a taller board, and the two counters a turn is now kept in
--
-- 'acts' is how many activations the side to move has spent, and 'active' is
-- the unit part-way through one (it has moved but not yet struck). A match
-- already in flight when this lands has neither, so everything below reads
-- them through coalesce and treats a missing 'active' as nobody.
-- ---------------------------------------------------------------------------
create or replace function public.cn_fresh_map()
returns jsonb language plpgsql as $$
declare v_w int := 6; v_h int := 8;
begin
  return jsonb_build_object(
    'v', 3,
    'board', jsonb_build_object('w', v_w, 'h', v_h),
    'phase', 'deploy',
    'ready', jsonb_build_object('host', false, 'guest', false),
    'obstacles', cn_gen_trees(v_w, v_h),
    'units', '[]'::jsonb,
    'turn', 'host',
    'turnNumber', 0,
    'acts', 0,
    'active', null,
    'idle', jsonb_build_object('host', 0, 'guest', 0),
    'away', null,
    'log', '[]'::jsonb,
    'winner', null);
end $$;

-- ---------------------------------------------------------------------------
-- 5. the budget
--
-- cn_acts_cap is the whole "first turn is short" rule. turnNumber is 1 for the
-- opening turn of a match (cn_set_ready sets it), so that turn gets one go and
-- every turn after it gets two. It reads <= 1 rather than = 1 so a match from
-- before this migration, which may carry no turnNumber at all, is treated as
-- opening rather than as unlimited.
-- ---------------------------------------------------------------------------
create or replace function public.cn_acts_cap(p_st jsonb)
returns int language sql immutable as $$
  select case when coalesce((p_st->>'turnNumber')::int, 1) <= 1 then 1 else 2 end
$$;

-- Open an activation, or carry on with the one already open. This is the only
-- place the budget is charged, so cn_move, cn_attack and cn_defend cannot
-- disagree about what a go costs.
create or replace function public.cn_begin_act(p_st jsonb, p_side text, p_unit text)
returns jsonb language plpgsql as $$
declare
  v_active text; v_acts int; v_cap int; u jsonb; v_me jsonb;
  v_out jsonb := '[]'::jsonb;
begin
  for u in select * from jsonb_array_elements(p_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if v_me->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
  if coalesce((v_me->>'spent')::boolean, false) then
    raise exception 'that unit has already had its go this turn';
  end if;

  v_active := nullif(p_st->>'active', '');
  v_acts   := coalesce((p_st->>'acts')::int, 0);
  v_cap    := cn_acts_cap(p_st);

  -- Already the active unit: it moved a moment ago and is now striking. Same
  -- go, nothing more to charge.
  if v_active is not distinct from p_unit then return p_st; end if;

  if v_acts >= v_cap then raise exception 'no actions left this turn'; end if;

  -- Turning to a different unit ends whatever the last one was in the middle
  -- of. It moved and chose not to strike; that was its go.
  if v_active is not null then
    for u in select * from jsonb_array_elements(p_st->'units') loop
      if u->>'id' = v_active then u := jsonb_set(u, '{spent}', 'true'::jsonb); end if;
      v_out := v_out || u;
    end loop;
    p_st := jsonb_set(p_st, '{units}', v_out);
  end if;

  p_st := jsonb_set(p_st, '{acts}', to_jsonb(v_acts + 1));
  p_st := jsonb_set(p_st, '{active}', to_jsonb(p_unit));
  return p_st;
end $$;

-- Close one deliberately: striking, defending, or saying you are done.
create or replace function public.cn_end_act(p_st jsonb, p_unit text)
returns jsonb language plpgsql as $$
declare u jsonb; v_out jsonb := '[]'::jsonb;
begin
  for u in select * from jsonb_array_elements(p_st->'units') loop
    if u->>'id' = p_unit then u := jsonb_set(u, '{spent}', 'true'::jsonb); end if;
    v_out := v_out || u;
  end loop;
  return jsonb_set(jsonb_set(p_st, '{units}', v_out), '{active}', 'null'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- 6. moving opens a go
-- ---------------------------------------------------------------------------
create or replace function public.cn_move(p_match uuid, p_side text, p_unit text, p_x integer, p_y integer)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; v_st jsonb; u jsonb; e jsonb; v_me jsonb;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_reach text[]; v_felled boolean := false;
begin
  select * into m from public.matches where id = p_match for update;
  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if v_me->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
  if (v_me->>'moved')::boolean then raise exception 'that unit already moved'; end if;

  -- Opens an activation, or continues the one this unit is already in.
  -- Moving deliberately does NOT close it: the unit may still strike, and
  -- move-then-strike is one action, not two. cn_begin_act is what charges
  -- the turn's budget, and it raises if there is nothing left to spend.
  v_st := cn_begin_act(v_st, p_side, p_unit);

  v_reach := cn_reach(v_st, v_me);
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

  -- A trampler can finish its move standing where a tree was. It is not there
  -- any more.
  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if (e->>'x')::int = p_x and (e->>'y')::int = p_y then v_felled := true;
    else v_rocks := v_rocks || e; end if;
  end loop;

  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
  v_st := state_log(v_st, (v_me->>'name') || ' advances.');
  if v_felled then
    v_st := state_log(v_st, (v_me->>'name') || ' walks through a tree. It comes down.');
  end if;

  update public.matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- 7. striking closes one, and a raised guard halves what lands
-- ---------------------------------------------------------------------------
create or replace function public.cn_attack(p_match uuid, p_side text, p_unit text, p_target text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; v_other text; v_st jsonb; u jsonb; e jsonb;
  v_atk jsonb; v_tgt jsonb; v_tree jsonb;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_dist int; v_dmg int := 0; v_heal int := 0;
  v_tgt_hp int; v_atk_hp int; v_counter int := 0; v_riposte int := 0;
  v_burn_atk int := 0; v_burn_tgt int := 0; v_new_burn boolean := false;
  v_cured boolean := false;
  v_answers boolean := false; v_parry boolean := false;
  v_reaches_back boolean := false; v_tgt_reaches boolean := false;
  v_hit_crit boolean := false;
  v_crit boolean := false; v_crit_counter boolean := false;
  v_chain int := 0; v_parries int := 0;
  v_swing_is_atk boolean := true; v_is_counter boolean := false;
  v_strk jsonb; v_recv jsonb; v_hit int; v_parried boolean;
  v_notes text[] := '{}';
  v_bloom jsonb := '[]'::jsonb; v_d2 int; v_got int; v_heal_roll int := 0;
  v_killed_tgt boolean := false; v_killed_atk boolean := false;
  v_ally boolean := false; v_foes int := 0; v_mine int := 0; v_win text;
  v_crown text; v_note text;
begin
  select * into m from public.matches where id = p_match for update;
  v_other := case when p_side = 'host' then 'guest' else 'host' end;
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
  if v_atk->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
  if (v_atk->>'acted')::boolean then raise exception 'that unit already acted'; end if;

  -- Striking spends an action whether or not this unit moved first. If it
  -- moved, it is already the active unit and this costs nothing further.
  v_st := cn_begin_act(v_st, p_side, p_unit);

  if v_tree is not null then
    v_dist := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                      (v_tree->>'x')::int, (v_tree->>'y')::int);
  else
    v_ally := (v_tgt->>'owner' = p_side);
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

  if v_ally then
    -- Mending is not an exchange: no crit, no parry, no answer.
    v_heal_roll := cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int);
    v_heal := v_heal_roll;
    v_tgt_hp := least((v_tgt->>'maxHp')::int, (v_tgt->>'hp')::int + v_heal);
    v_heal := v_tgt_hp - (v_tgt->>'hp')::int;
    v_cured := coalesce((v_atk->>'cures')::boolean, false)
               and coalesce((v_tgt->>'burned')::boolean, false);
    v_note := (v_atk->>'name') || ' mends ' || (v_tgt->>'name') || ' for ' || v_heal || '.';

    -- A flower does not choose who it grows for. One roll, spent on everyone
    -- standing in reach, so the answer to Sinie is to keep your line apart --
    -- which is the opposite of what every other unit wants of you.
    if coalesce((v_atk->>'blooms')::boolean, false) then
      for u in select * from jsonb_array_elements(v_st->'units') loop
        continue when u->>'id' = p_unit or u->>'id' = p_target;
        continue when u->>'owner' <> p_side;
        continue when (u->>'hp')::int >= (u->>'maxHp')::int;
        v_d2 := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                        (u->>'x')::int, (u->>'y')::int);
        continue when v_d2 < (v_atk->>'rmin')::int or v_d2 > (v_atk->>'rmax')::int;
        continue when not cn_los_clear(v_st, (v_atk->>'x')::int, (v_atk->>'y')::int,
                                       (u->>'x')::int, (u->>'y')::int);
        v_bloom := v_bloom || jsonb_build_array(u->>'id');
      end loop;
    end if;

  elsif v_tree is not null then
    -- A tree does not parry and does not answer, but a crit still fells it.
    v_crit := cn_chance((v_atk->>'critPct')::int, 'crit');
    v_dmg := cn_damage(cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int), v_crit, false);
    v_tgt_hp := (v_tree->>'hp')::int - v_dmg;
    v_killed_tgt := v_tgt_hp <= 0;
    if (v_atk->>'burned')::boolean then v_burn_atk := 5; v_atk_hp := v_atk_hp - 5; end if;
    v_killed_atk := v_atk_hp <= 0;
    v_note := (v_atk->>'name') || ' strikes a tree for ' || v_dmg
              || case when v_killed_tgt then ' -- it falls.' else '.' end;

  else
    v_tgt_hp := (v_tgt->>'hp')::int;

    -- A thief that trades blows is not a thief.
    v_answers := not coalesce((v_atk->>'sneaks')::boolean, false)
                 and v_dist >= (v_tgt->>'crmin')::int
                 and v_dist <= (v_tgt->>'crmax')::int;
    -- v_answers is the ORDINARY counter, and Quick Dagger spends it. Whether
    -- each side can physically reach the other is a separate, permanent fact,
    -- and it is the one a parry asks: a parrier answers only if the blow it
    -- caught came from somewhere it can reach.
    v_tgt_reaches  := v_answers;
    v_reaches_back := v_dist >= (v_atk->>'crmin')::int
                  and v_dist <= (v_atk->>'crmax')::int;

    -- Quick Dagger. The answer lands before the blow it is answering, and it
    -- is a passive, so nothing catches it. It spends the ordinary counter --
    -- you do not get to answer twice for one attack.
    if v_answers and coalesce((v_tgt->>'parries')::boolean, false) then
      v_crit_counter := cn_chance((v_tgt->>'critPct')::int, 'crit');
      v_counter := cn_damage(cn_roll((v_tgt->>'dmin')::int, (v_tgt->>'dmax')::int),
                             v_crit_counter, true, 0, 0,
                             coalesce((v_atk->>'defending')::boolean, false));
      v_atk_hp := v_atk_hp - v_counter;
      if (v_tgt->>'burned')::boolean then
        v_burn_tgt := 5; v_tgt_hp := v_tgt_hp - 5;
      end if;
      v_killed_atk := v_atk_hp <= 0;
      v_killed_tgt := v_tgt_hp <= 0;
      v_parry   := true;          -- the clients draw this the same way
      v_answers := false;
      v_notes := v_notes || ((v_tgt->>'name') || ' answers first for ' || v_counter
                 || case when v_crit_counter then ' -- a critical hit.' else '.' end);
    end if;

    -- The chain.
    while not v_killed_atk and not v_killed_tgt and v_chain < cn_parry_cap() loop
      v_chain := v_chain + 1;
      if v_swing_is_atk
        then v_strk := v_atk; v_recv := v_tgt;
        else v_strk := v_tgt; v_recv := v_atk;
      end if;

      -- Lium catches any answer-to-a-parry aimed at him. Everyone else rolls.
      v_parried := (v_is_counter and coalesce((v_recv->>'parryAll')::boolean, false))
                   or cn_chance((v_recv->>'parryPct')::int, 'parry');

      if v_parried then
        v_parries := v_parries + 1;
        if v_chain = 1 then v_parry := true; end if;
        v_notes := v_notes || ((v_recv->>'name') || ' parries '
                   || (v_strk->>'name') || '.');
        -- A parry answers only if the parrier can reach what it caught.
        exit when not case when v_swing_is_atk then v_tgt_reaches
                                               else v_reaches_back end;
        v_swing_is_atk := not v_swing_is_atk;
        v_is_counter := true;
        continue;
      end if;

      -- The blow lands.
      v_hit_crit := cn_chance((v_strk->>'critPct')::int, 'crit');
      v_hit := cn_damage(cn_roll((v_strk->>'dmin')::int, (v_strk->>'dmax')::int),
                         v_hit_crit, v_is_counter, 0, 0,
                         coalesce((v_recv->>'defending')::boolean, false));
      if v_swing_is_atk then
        v_tgt_hp := v_tgt_hp - v_hit;
        if v_is_counter then v_riposte := v_riposte + v_hit;
        else v_dmg := v_hit; v_crit := v_hit_crit; end if;
      else
        v_atk_hp := v_atk_hp - v_hit;
        v_counter := v_counter + v_hit;
        v_crit_counter := v_crit_counter or v_hit_crit;
      end if;
      if v_is_counter then
        v_notes := v_notes || ((v_strk->>'name') || ' answers for ' || v_hit
                   || case when v_hit_crit then ' -- a critical hit.' else '.' end);
      end if;

      -- Swinging while alight costs you, whichever end of the exchange you are.
      if (v_strk->>'burned')::boolean then
        if v_swing_is_atk
          then v_burn_atk := 5; v_atk_hp := v_atk_hp - 5;
          else v_burn_tgt := 5; v_tgt_hp := v_tgt_hp - 5;
        end if;
      end if;
      v_killed_atk := v_atk_hp <= 0;
      v_killed_tgt := v_tgt_hp <= 0;
      exit when v_killed_atk or v_killed_tgt;

      -- A blow that lands draws the ordinary counter. A counter that lands
      -- ends it -- otherwise the two of them never stop.
      exit when v_is_counter;
      exit when not v_answers;
      v_swing_is_atk := false;
      v_is_counter := true;
    end loop;

    v_new_burn := (v_atk->>'burns')::boolean and not v_killed_tgt and v_dmg > 0;

    if v_dmg = 0 then
      v_note := (v_atk->>'name') || ' lunges at ' || (v_tgt->>'name') || '.';
    else
      v_note := (v_atk->>'name') || ' hits ' || (v_tgt->>'name') || ' for ' || v_dmg
                || case when v_killed_tgt and v_burn_tgt = 0 then ' -- destroyed.' else '.' end;
    end if;
  end if;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      if not v_killed_atk then
        u := jsonb_set(u, '{acted}', 'true'::jsonb);
        u := jsonb_set(u, '{moved}', 'true'::jsonb);
        u := jsonb_set(u, '{spent}', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb(v_atk_hp));
        v_out := v_out || u;
      end if;
    elsif v_tree is null and u->>'id' = p_target then
      if v_ally then
        u := jsonb_set(u, '{hp}', to_jsonb(v_tgt_hp));
        if v_cured then u := jsonb_set(u, '{burned}', 'false'::jsonb); end if;
        v_out := v_out || u;
      elsif not v_killed_tgt then
        u := jsonb_set(u, '{hp}', to_jsonb(v_tgt_hp));
        if v_new_burn then u := jsonb_set(u, '{burned}', 'true'::jsonb); end if;
        v_out := v_out || u;
      end if;
    elsif v_bloom @> jsonb_build_array(u->>'id') then
      v_got := least((u->>'maxHp')::int - (u->>'hp')::int, v_heal_roll);
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int + v_got));
      if coalesce((v_atk->>'cures')::boolean, false) then
        u := jsonb_set(u, '{burned}', 'false'::jsonb);
      end if;
      v_out := v_out || u;
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
  -- Set on the state rather than through cn_end_act: an attacker killed by
  -- the counter has already been dropped from v_out, so there is no row
  -- left to flag, and the activation still has to end.
  v_st := jsonb_set(v_st, '{active}', 'null'::jsonb);
  v_st := jsonb_set(v_st, '{fx}', jsonb_build_object(
    'seq', coalesce((v_st->'fx'->>'seq')::int, 0) + 1,
    'atk', p_unit, 'tgt', p_target,
    'dmg', v_dmg, 'heal', v_heal,
    'killedTgt', v_killed_tgt, 'counter', v_counter, 'killedAtk', v_killed_atk,
    'burnAtk', v_burn_atk, 'burnTgt', v_burn_tgt, 'newBurn', v_new_burn,
    'cured', v_cured, 'parry', v_parry, 'bloom', v_bloom,
    'crit', v_crit, 'critCounter', v_crit_counter,
    'parries', v_parries, 'chain', v_chain, 'riposte', v_riposte,
    'tree', (v_tree is not null)));

  v_st := state_log(v_st, v_note);
  if jsonb_array_length(v_bloom) > 0 then
    v_st := state_log(v_st, 'The bloom spreads -- '
      || jsonb_array_length(v_bloom) || ' more mended.');
  end if;
  if v_cured then v_st := state_log(v_st, (v_tgt->>'name') || ' stops burning.'); end if;
  if v_new_burn then v_st := state_log(v_st, (v_tgt->>'name') || ' is burning.'); end if;
  foreach v_note in array v_notes loop
    v_st := state_log(v_st, v_note);
  end loop;
  if v_killed_atk and v_burn_atk = 0 and v_counter > 0 then
    v_st := state_log(v_st, (v_atk->>'name') || ' is destroyed.');
  end if;
  if v_burn_tgt > 0 then
    v_st := state_log(v_st, (v_tgt->>'name') || ' burns for ' || v_burn_tgt
      || case when v_killed_tgt then ' -- destroyed.' else '.' end);
  end if;
  if v_burn_atk > 0 then
    v_st := state_log(v_st, (v_atk->>'name') || ' burns for ' || v_burn_atk
      || case when v_killed_atk then ' -- destroyed.' else '.' end);
  end if;

  -- ---- who has won -------------------------------------------------------
  -- A crown that falls takes the kingdom with it. Checked before the count of
  -- bodies, because a king can die while four of his units are still standing
  -- and that is still over. The defender is checked first: the attack resolved,
  -- so if both crowns fell in the one exchange the one that was struck fell
  -- first.
  if v_tree is null and v_killed_tgt and coalesce((v_tgt->>'royal')::boolean, false) then
    v_crown := v_tgt->>'owner';
  elsif v_killed_atk and coalesce((v_atk->>'royal')::boolean, false) then
    v_crown := v_atk->>'owner';
  end if;

  for u in select * from jsonb_array_elements(v_out) loop
    if u->>'owner' = p_side then v_mine := v_mine + 1; else v_foes := v_foes + 1; end if;
  end loop;

  if v_crown is not null and not exists (
       select 1 from jsonb_array_elements(v_out) q
        where q->>'owner' = v_crown and (q->>'royal')::boolean) then
    v_win := case when v_crown = 'host' then 'guest' else 'host' end;
    v_st := state_log(v_st, 'The crown has fallen.');
  elsif v_foes = 0 then v_win := p_side;
  elsif v_mine = 0 then v_win := v_other;
  end if;

  if v_win is not null then
    if m.ranked then perform finish_match(m.id, v_win, 'defeat'); end if;
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
end
$$;

-- ---------------------------------------------------------------------------
-- 8. Defend, and Wait
--
-- Defend raises a guard that lasts until this unit's own next turn, so it is
-- still up while the opponent is swinging -- which is the only time it could
-- matter. It costs the activation and ends it. A unit may move and then
-- defend; that is still one go.
--
-- Wait is the other half of the action menu: a unit that moved and does not
-- want to strike needs a way to say so, otherwise its go stays open and the
-- second activation cannot start cleanly.
-- ---------------------------------------------------------------------------
create or replace function public.cn_defend(p_match uuid, p_side text, p_unit text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare m public.matches; v_st jsonb; u jsonb; v_me jsonb; v_out jsonb := '[]'::jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if v_me->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
  if (v_me->>'acted')::boolean then raise exception 'that unit already acted'; end if;

  v_st := cn_begin_act(v_st, p_side, p_unit);

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      u := jsonb_set(u, '{defending}', 'true'::jsonb);
      u := jsonb_set(u, '{acted}', 'true'::jsonb);
    end if;
    v_out := v_out || u;
  end loop;
  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := cn_end_act(v_st, p_unit);
  v_st := state_log(v_st, (v_me->>'name') || ' raises a guard.');

  update public.matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

create or replace function public.submit_defend(p_match uuid, p_unit text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare m public.matches; v_side text;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.state->>'turn' <> v_side then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then raise exception 'your time ran out'; end if;
  return cn_defend(p_match, v_side, p_unit);
end $$;

create or replace function public.submit_wait(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare m public.matches; v_side text; v_active text; v_st jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.state->>'turn' <> v_side then raise exception 'not your turn'; end if;

  v_st := m.state;
  v_active := nullif(v_st->>'active', '');
  if v_active is null then return m; end if;   -- nobody mid-go; nothing to end

  v_st := cn_end_act(v_st, v_active);
  update public.matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

-- ---------------------------------------------------------------------------
-- 9. a new turn is a fresh budget, and guards drop
-- ---------------------------------------------------------------------------
create or replace function public.advance_turn(p_match uuid, p_note text, p_timeout boolean)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; st jsonb; u jsonb; out_u jsonb := '[]'::jsonb;
  v_who text; v_next text; v_turn int; v_did boolean := false; v_n int;
begin
  select * into m from public.matches where id = p_match for update;
  st := m.state;
  v_who  := st->>'turn';
  v_next := case when v_who = 'host' then 'guest' else 'host' end;
  v_turn := coalesce((st->>'turnNumber')::int, 1) + 1;

  -- Did the side whose turn is ending actually do anything with it?
  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'owner' = v_who and ((u->>'moved')::boolean or (u->>'acted')::boolean) then
      v_did := true;
    end if;
    u := jsonb_set(u, '{moved}', 'false'::jsonb);
    u := jsonb_set(u, '{acted}', 'false'::jsonb);
    u := jsonb_set(u, '{spent}', 'false'::jsonb);
    -- A guard is raised on your turn and has to survive the opponent's, so
    -- it lapses when its owner's next turn opens -- not when it is tested.
    if u->>'owner' = v_next then
      u := jsonb_set(u, '{defending}', 'false'::jsonb);
    end if;
    out_u := out_u || u;
  end loop;

  if st->'idle' is null then
    st := jsonb_set(st, '{idle}', jsonb_build_object('host', 0, 'guest', 0));
  end if;
  v_n := coalesce((st->'idle'->>v_who)::int, 0);
  if p_timeout and not v_did then v_n := v_n + 1; else v_n := 0; end if;
  st := jsonb_set(st, array['idle', v_who], to_jsonb(v_n));

  if v_n >= 3 then
    if coalesce(st->>'away', '') <> v_who then
      st := state_log(st,
        case when v_who = 'host' then m.host_name else m.guest_name end
        || ' has not acted for three turns.');
    end if;
    st := jsonb_set(st, '{away}', to_jsonb(v_who));
  elsif st->>'away' = v_who then
    st := jsonb_set(st, '{away}', 'null'::jsonb);
    st := state_log(st,
      case when v_who = 'host' then m.host_name else m.guest_name end || ' is back.');
  end if;

  st := jsonb_set(st, '{units}', out_u);
  st := jsonb_set(st, '{acts}', '0'::jsonb);
  st := jsonb_set(st, '{active}', 'null'::jsonb);
  st := jsonb_set(st, '{turn}', to_jsonb(v_next));
  st := jsonb_set(st, '{turnNumber}', to_jsonb(v_turn));
  if p_note is not null then st := state_log(st, p_note); end if;
  st := state_log(st, 'Turn ' || v_turn || ' — '
        || case when v_next = 'host' then m.host_name else m.guest_name end || ' to act.');

  update public.matches
     set state = st, turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- 9b. and the bot plays by it
-- ---------------------------------------------------------------------------
create or replace function public.bot_step(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; st jsonb; v_lvl int; v_noise numeric;
  u jsonb; t jsonb;
  v_tiles text[]; v_tile text; vx int; vy int; v_first boolean;
  v_best numeric := 0; v_bu text; v_bx int; v_by int; v_bt text;
  -- The best action that does SOMETHING, however badly it scores. Only used
  -- when nothing at all beat "leave everyone where they are" -- see the note
  -- at the bottom of this function.
  v_fb numeric := -1e9; v_fu text; v_fbx int; v_fby int; v_ft text;
  v_pos numeric; v_base numeric; v_act numeric; v_step_s numeric;
  v_d int; v_dmg numeric; v_ctr numeric; v_near int; v_thr int;
  v_answers boolean; v_parry boolean;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null or m.bot is null then return m; end if;
  if m.status <> 'active' then return m; end if;
  if m.state->>'turn' <> 'guest' then return m; end if;

  v_lvl := m.bot;
  st := m.state;

  -- Every candidate is scored as a CHANGE from leaving that unit where it is
  -- and doing nothing with it. Raw scores are not comparable between units --
  -- a Titan standing in a good spot would outrank an Archer that badly wants
  -- to move -- but "how much better does this make things" is. Nothing beating
  -- zero means there is nothing worth doing, and the turn ends.
  for u in select * from jsonb_array_elements(st->'units') loop
    continue when u->>'owner' <> 'guest';
    continue when (u->>'moved')::boolean and (u->>'acted')::boolean;
    continue when coalesce((u->>'spent')::boolean, false);
    continue when coalesce((st->>'acts')::int, 0) >= cn_acts_cap(st)
              and nullif(st->>'active', '') is distinct from u->>'id';

    v_tiles := array[(u->>'x') || ',' || (u->>'y')];   -- staying put comes first
    if not (u->>'moved')::boolean then
      v_tiles := v_tiles || cn_reach(st, u);   -- flying and trampling included
    end if;
    v_first := true;

    foreach v_tile in array v_tiles loop
      vx := split_part(v_tile, ',', 1)::int;
      vy := split_part(v_tile, ',', 2)::int;

      -- ---- what standing there is worth, before doing anything -----------
      v_near := 99; v_thr := 0;
      for t in select * from jsonb_array_elements(st->'units') loop
        continue when t->>'owner' = 'guest';
        v_d := cn_cheb(vx, vy, (t->>'x')::int, (t->>'y')::int);
        v_near := least(v_near, v_d);
        -- a tile they could walk to and then strike from
        if v_d <= (t->>'mov')::int + (t->>'rmax')::int then v_thr := v_thr + 1; end if;
      end loop;
      -- a unit wants to be at exactly its own reach, not merely close
      -- It wants to be at exactly its own reach -- but a small, never-zero
      -- pull toward the enemy on top of that. Without it two units whose line
      -- is blocked by a tree both sit at their ideal distance scoring zero,
      -- neither can shoot, moving scores worse, and the match never ends.
      v_pos := - abs(v_near - (u->>'rmax')::int) * 5.0 - v_near * 2.0;

      if v_first then v_base := v_pos; v_first := false; end if;

      -- ---- moving there and doing nothing else ---------------------------
      -- Standing still is the BASELINE, not a candidate. It used to be one, and
      -- because every score carries noise it would regularly win -- at which
      -- point bot_step ended the whole turn, even though other units still had
      -- good moves. Against a defender the bot did not want to trade with,
      -- that repeated forever and the match never finished.
      if vx <> (u->>'x')::int or vy <> (u->>'y')::int then
        v_noise := random() * (case v_lvl when 1 then 220 when 2 then 90 else 15 end);
        -- Walking into somebody's reach for no reason is what the careful one
        -- avoids. Walking into it to hit them is a trade, and the trade maths
        -- below already prices that -- charging this twice is what made
        -- RUTHLESS hover one tile outside everybody's range for three hundred
        -- turns rather than ever start a fight.
        v_step_s := v_pos - v_base + v_noise;
        if v_lvl >= 3 then v_step_s := v_step_s - v_thr * 4.0; end if;
        if v_step_s > v_best then
          v_best := v_step_s;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := null;
        end if;
        if v_step_s > v_fb then
          v_fb := v_step_s;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null;
        end if;
      end if;

      continue when (u->>'acted')::boolean;

      -- ---- and everything it could act on from there ----------------------
      for t in select * from jsonb_array_elements(st->'units') loop
        continue when t->>'id' = u->>'id';
        v_d := cn_cheb(vx, vy, (t->>'x')::int, (t->>'y')::int);
        continue when v_d < (u->>'rmin')::int or v_d > (u->>'rmax')::int;
        continue when not cn_los_clear(st, vx, vy, (t->>'x')::int, (t->>'y')::int);

        v_dmg := ((u->>'dmin')::int + (u->>'dmax')::int) / 2.0;

        if t->>'owner' = 'guest' then
          continue when not (u->>'heals')::boolean;
          -- mending someone already whole is a wasted turn
          v_act := case when (t->>'maxHp')::int - (t->>'hp')::int <= 0 then -150
                        else least(v_dmg, (t->>'maxHp')::int - (t->>'hp')::int) * 9.0 end;
        else
          v_answers := not coalesce((u->>'sneaks')::boolean, false)
                       and v_d >= (t->>'crmin')::int and v_d <= (t->>'crmax')::int;
          v_parry := v_answers and coalesce((t->>'parries')::boolean, false);

          v_act := least(v_dmg, (t->>'hp')::int) * 10.0;
          if v_dmg >= (t->>'hp')::int then
            v_act := v_act + 400 + (t->>'maxHp')::int;          -- a kill is worth a lot
          elsif (u->>'burns')::boolean and not (t->>'burned')::boolean then
            v_act := v_act + 25;
          end if;

          -- What comes back. A parry answers BEFORE the blow, so it is charged
          -- even when the blow would have been lethal -- and if the answer is
          -- lethal in turn, the blow never happens and the kill counted above
          -- was imaginary.
          if v_answers and (v_parry or v_dmg < (t->>'hp')::int) then
            v_ctr := ((t->>'dmin')::int + (t->>'dmax')::int) / 2.0;
            -- Loss-averse, but LESS than a point of damage dealt is worth,
            -- or an even trade scores negative and the bot will not take it.
            -- At 12 it flatly refused to touch Dione & Grifo, whose counter
            -- is nearly as hard as most units' attack -- so it stood next to
            -- them until the clock ran out, every time.
            v_act := v_act - v_ctr * (case v_lvl when 1 then 3.0 else 8.0 end);
            if v_ctr >= (u->>'hp')::int then
              v_act := v_act - 500 - (u->>'maxHp')::int
                       - case when v_parry then 400 + (t->>'maxHp')::int else 0 end;
            end if;
          end if;
        end if;

        v_noise := random() * (case v_lvl when 1 then 220 when 2 then 90 else 15 end);
        if v_pos + v_act - v_base + v_noise > v_best then
          v_best := v_pos + v_act - v_base + v_noise;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := t->>'id';
        end if;
        if v_pos + v_act - v_base + v_noise > v_fb then
          v_fb := v_pos + v_act - v_base + v_noise;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t->>'id';
        end if;
      end loop;
    end loop;
  end loop;

  -- Nothing was worth doing. That is not the same as "do nothing", because a
  -- board where neither side will move is a match that never ends -- and it
  -- happened: against Dione & Grifo, whose counter is nearly as hard as most
  -- units' attack, every strike scored worse than standing still, so the bot
  -- stood next to them until the clock ran out. When every option is bad it
  -- takes the least bad one that actually does something. Somebody always
  -- takes damage, so the game always finishes.
  if v_bu is null and v_fu is not null then
    v_bu := v_fu; v_bx := v_fbx; v_by := v_fby; v_bt := v_ft;
  end if;
  if v_bu is null then return advance_turn(p_match, null, false); end if;

  -- One thing per call. If the plan was to walk somewhere and then strike, the
  -- walk happens now and the strike is the next step -- which is what makes it
  -- watchable instead of instantaneous.
  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'id' = v_bu and ((u->>'x')::int <> v_bx or (u->>'y')::int <> v_by) then
      return cn_move(p_match, 'guest', v_bu, v_bx, v_by);
    end if;
  end loop;

  if v_bt is not null then return cn_attack(p_match, 'guest', v_bu, v_bt); end if;
  return advance_turn(p_match, null, false);
end
$$;

-- ---------------------------------------------------------------------------
-- 10. who may call what
--
-- The cn_* functions hold the rules and take an explicit side, so they stay
-- shut to clients; the submit_* shells work out who you are and are the way in.
-- ---------------------------------------------------------------------------
revoke execute on function public.cn_defend(uuid, text, text)   from public, anon, authenticated;
revoke execute on function public.cn_begin_act(jsonb, text, text) from public, anon, authenticated;
revoke execute on function public.cn_end_act(jsonb, text)       from public, anon, authenticated;
grant  execute on function public.cn_acts_cap(jsonb)            to authenticated, anon;
grant  execute on function public.submit_defend(uuid, text)     to authenticated;
grant  execute on function public.submit_wait(uuid)             to authenticated;

-- ---------------------------------------------------------------------------
-- 11. Did it work? All true means yes.
-- ---------------------------------------------------------------------------
with m as (select public.cn_fresh_map() as st),
     t as (select public.cn_gen_trees(6, 8) as o),
     a as (select public.cn_army(public.cn_fresh_map(), 'host',  public.default_deck()) as u),
     b as (select public.cn_army(public.cn_fresh_map(), 'guest', public.default_deck()) as u)
select
  (select (st->'board'->>'w')::int = 6 and (st->'board'->>'h')::int = 8 from m)
                                                                as board_is_six_by_eight,
  public.cn_own_side('host', 0, 8) and not public.cn_own_side('host', 7, 8)
                                                                as host_holds_the_bottom,
  public.cn_own_side('guest', 7, 8) and not public.cn_own_side('guest', 0, 8)
                                                                as guest_holds_the_top,
  (select bool_and((e->>'y')::int < 4) from a, jsonb_array_elements(a.u) e)
                                                                as host_starts_low,
  (select bool_and((e->>'y')::int >= 4) from b, jsonb_array_elements(b.u) e)
                                                                as guest_starts_high,
  (select jsonb_array_length(o) = 8 from t)                     as eight_trees_in_all,
  (select count(*) = 4 from t, jsonb_array_elements(t.o) e where (e->>'y')::int < 4)
                                                                as four_trees_each_side,
  (select bool_and((e->>'y')::int between 1 and 6)
     from t, jsonb_array_elements(t.o) e)                       as no_tree_on_a_home_row,
  public.cn_acts_cap('{"turnNumber":1}'::jsonb) = 1              as opening_turn_is_one_go,
  public.cn_acts_cap('{"turnNumber":2}'::jsonb) = 2              as every_later_turn_is_two,
  public.cn_damage(30, false, false, 0, 0, true) = 15            as defending_still_halves_it,
  to_regprocedure('public.submit_defend(uuid, text)') is not null as defend_is_reachable,
  to_regprocedure('public.submit_wait(uuid)') is not null         as wait_is_reachable;
