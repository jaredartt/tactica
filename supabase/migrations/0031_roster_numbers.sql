-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0030 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0031 - PHASE F1: the numbers, the classes and the crowns
--
--  The roster spec in project_status.md section 6 is the design. The eleven
--  cards in this database have never been it. Dereo has been a 70-point unit
--  against the spec's 110-point Royal; Wuzu a 120-point trampler against an
--  85-point flier; Himanta has flown while the spec calls it a Rogue. Since
--  0023 a card's TEXT has been the spec's and its NUMBERS have not, and this
--  file has said so in writing for two phases: "from 0023 until the roster
--  rework, a card's text is a promise rather than a description".
--
--  This is the first half of keeping that promise, and it deliberately
--  introduces NO NEW MECHANICS. It is the largest diff of the phase and the
--  least dangerous one, which is why it goes first.
--
--  WHAT CHANGES
--
--  1. A CLASS IS A CLASS. `role` was free text -- Swordsmen, Monster, Bandit,
--     Herbalist, Seer -- and nothing read it. It is now one of five checked
--     values (royal, rogue, knight, mage, flying), which is what the Royal
--     auras below match on, and the word on screen is translated rather than
--     stored in English.
--
--  2. THE NUMBERS ARE THE SPEC'S. HP, damage, movement and range for all
--     eleven. `power` is already the single damage number the spec has and
--     dmin/dmax are the dice around it, so the trigger derives them now
--     instead of a one-off UPDATE doing it once in 0018 and never again.
--
--  3. NINE UNITS ARRIVE, AND NONE OF THEM IS PLAYABLE YET. Queen Miah, King
--     Stelaris, Dorme, Ashvar, Velmor, Sarrave, Thalgrim, Nyxara and Zephyra
--     land inactive, with their spec text in both languages and no art. They
--     switch on when their ability exists -- shipping a card whose sentence
--     describes something that does not happen is the exact thing this phase
--     is here to end, and doing it nine more times on the way would be a
--     strange way to end it.
--
--  4. FLIGHT FOLLOWS THE CLASS. `flies` is derived from `role = 'flying'`
--     rather than being a flag somebody could set on a Knight. Two live cards
--     change because of it: Himanta stops flying (the spec makes it a Rogue)
--     and Wuzu starts (the spec makes it Flying). Wuzu also stops felling
--     trees -- trampling is nowhere in the spec, and a flier goes over them
--     anyway.
--
--  5. THE ROYAL AURAS, which cost almost nothing. `cn_damage` has carried
--     `p_bonus` and `p_resist` since 0018 with a comment saying they "are the
--     hook the royal passives and the class resistances will hang on", and
--     nothing has ever passed them anything but zero. Three columns on the
--     card and two small functions is the whole of it:
--
--       King Dereo    - the team takes 20% less from Knights
--       Queen Miah    - the team deals 20% more to Mages
--       King Stelaris - the team takes 50% less burn and poison
--
--     They are PASSIVE. The spec writes them with an "A:" marker but they
--     describe permanent team effects, and Jared has confirmed they are never
--     activated. Miah and Stelaris are inactive, so only Dereo's is reachable
--     today -- but all three are built, because building two of them later
--     would mean reading this file again to remember how the first one works.
--
--     THE AURA TRAVELS ON THE UNIT SNAPSHOT, not looked up from `cards` at
--     damage time. Units are snapshotted at deployment and that is correct for
--     stats: retuning a card in the admin editor must not change the strength
--     of a match already being played.
--
--  WHAT DOES NOT CHANGE. Every ability and passive behaves exactly as it did
--  yesterday -- burns, mends, cures, parries, blooms, sneaks are all still
--  wired the way 0010 to 0020 wired them. The spec's abilities are F3's
--  business. Slugs are untouched, so every saved kingdom still points at
--  something.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. what an aura is
--
-- Three columns rather than a table: an aura belongs to a card the way `royal`
-- does, there are three of them in the whole game, and a table would be a join
-- to answer a question a column answers.
-- ---------------------------------------------------------------------------
alter table public.cards add column if not exists aura_kind  text;
alter table public.cards add column if not exists aura_class text;
alter table public.cards add column if not exists aura_pct   int;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'cards_aura_kind_check') then
    alter table public.cards add constraint cards_aura_kind_check
      check (aura_kind is null or aura_kind in ('resist', 'bonus', 'resist_effects'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'cards_aura_pct_check') then
    alter table public.cards add constraint cards_aura_pct_check
      check (aura_pct is null or (aura_pct >= 0 and aura_pct <= 100));
  end if;
end $$;

create or replace function public.cn_classes() returns text[]
language sql immutable as $$
  select array['royal', 'rogue', 'knight', 'mage', 'flying']
$$;

-- ---------------------------------------------------------------------------
-- 2. the card trigger, which now derives four things instead of guarding them
--
-- Spliced from 0030 verbatim; the class block and the dice are the only
-- additions. `power` has been described as "what a player reads, and dmin/dmax
-- are the dice derived from it" since 0018 -- but nothing derived them after
-- 0018's one-off UPDATE, so a card edited since then has had whatever pair of
-- numbers was typed. It derives them now, every time.
-- ---------------------------------------------------------------------------
create or replace function public.cn_check_card()
returns trigger language plpgsql as $$
begin
  new.slug := nullif(lower(btrim(coalesce(new.slug, ''))), '');
  new.name := btrim(coalesce(new.name, ''));
  new.role := lower(btrim(coalesce(new.role, '')));
  new.accent := lower(btrim(coalesce(new.accent, '')));
  new.art_url := nullif(btrim(coalesce(new.art_url, '')), '');
  new.ability := btrim(coalesce(new.ability, ''));
  new.ability_es := nullif(btrim(coalesce(new.ability_es, '')), '');

  if new.is_active and new.slug is null then
    raise exception 'a card needs a slug';
  end if;
  if new.slug is not null and new.slug !~ '^[a-z][a-z0-9-]{1,39}$' then
    raise exception 'a slug is lower case letters, digits and dashes: %', new.slug;
  end if;
  if new.is_active and new.name = '' then
    raise exception 'a card needs a name';
  end if;

  if new.accent !~ '^#[0-9a-f]{6}$' then
    raise exception 'an accent is six hex digits, like #2f4bff -- got %', new.accent;
  end if;

  -- ---- the class ----------------------------------------------------------
  -- Five of them, and they are matched on by the auras below, so a sixth
  -- spelled by hand would be a card no resistance could ever see.
  if new.role <> '' and not (new.role = any(cn_classes())) then
    raise exception 'a class is one of %, got %',
      array_to_string(cn_classes(), ', '), new.role;
  end if;
  if new.is_active and new.role = '' then
    raise exception 'a card needs a class';
  end if;
  -- Flight belongs to the class, not to a flag somebody can set on a Knight.
  new.flies := (new.role = 'flying');
  -- And the crown: three Royals in the spec, and `royal` is what the
  -- one-crown kingdom rule and the losing condition both read.
  new.royal := (new.role = 'royal');

  if new.mov < 0 or new.mov > 12 then
    raise exception 'a move is 0 to 12';
  end if;

  -- ---- one reach number, and it starts at 1 (0030) ------------------------
  new.range := coalesce(nullif(new.range, 0), nullif(new.rmax, 0), 1);
  if new.range < 1 or new.range > 12 then
    raise exception 'a range is 1 to 12 -- got %', new.range;
  end if;
  new.rmax  := new.range;
  new.rmin  := 1;
  new.crmin := 1;
  new.crmax := new.range;

  -- ---- and one damage number, with the dice around it ---------------------
  if new.power is not null then
    if new.power < 1 or new.power > 200 then
      raise exception 'a power is 1 to 200';
    end if;
    new.dmin := greatest(0, new.power - cn_spread());
    new.dmax := new.power + cn_spread();
    new.attack := new.power;
  end if;

  -- ---- the aura -----------------------------------------------------------
  if new.aura_kind is not null then
    if not new.royal then
      raise exception 'only a Royal carries an aura -- % is a %', new.name, new.role;
    end if;
    if new.aura_kind in ('resist', 'bonus')
       and not (coalesce(new.aura_class, '') = any(cn_classes())) then
      raise exception 'an aura that names a class needs one of %, got %',
        array_to_string(cn_classes(), ', '), coalesce(new.aura_class, '(null)');
    end if;
    if coalesce(new.aura_pct, 0) <= 0 then
      raise exception 'an aura with no percentage does nothing';
    end if;
  end if;

  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 3. reading an aura off the board
--
-- Two functions rather than one returning a pair, because the call sites read
-- better: cn_damage takes a bonus and a resistance in that order, and two
-- named things line up with it.
--
-- A royal grants its aura while it stands. That is the honest rule even though
-- it can never be false in a match -- losing your royal ENDS the match, so a
-- side without one is a side that has already lost.
-- ---------------------------------------------------------------------------
create or replace function public.cn_aura(p_state jsonb, p_side text, p_kind text)
returns jsonb language sql stable as $$
  select u
    from jsonb_array_elements(coalesce(p_state->'units', '[]'::jsonb)) u
   where u->>'owner' = p_side
     and coalesce((u->>'royal')::boolean, false)
     and (u->>'hp')::int > 0
     and u->>'auraKind' = p_kind
   limit 1
$$;

/** What the swinger's own crown adds, against this receiver's class. */
create or replace function public.cn_aura_bonus(p_state jsonb, p_swinger jsonb, p_receiver jsonb)
returns numeric language plpgsql stable as $$
declare v jsonb;
begin
  if p_swinger is null or p_receiver is null then return 0; end if;
  v := cn_aura(p_state, p_swinger->>'owner', 'bonus');
  if v is null then return 0; end if;
  if v->>'auraClass' is distinct from p_receiver->>'role' then return 0; end if;
  return coalesce((v->>'auraPct')::numeric, 0) / 100;
end $$;

/** What the receiver's own crown takes off, against this swinger's class. */
create or replace function public.cn_aura_resist(p_state jsonb, p_swinger jsonb, p_receiver jsonb)
returns numeric language plpgsql stable as $$
declare v jsonb;
begin
  if p_swinger is null or p_receiver is null then return 0; end if;
  v := cn_aura(p_state, p_receiver->>'owner', 'resist');
  if v is null then return 0; end if;
  if v->>'auraClass' is distinct from p_swinger->>'role' then return 0; end if;
  return coalesce((v->>'auraPct')::numeric, 0) / 100;
end $$;

-- cn_classes() is NOT revoked, and that is not an oversight. cn_check_card
-- is a plain trigger function -- it runs as whoever is writing the row, not
-- as the definer -- so revoking the list of five class names would turn a
-- non-admin's refused INSERT into "permission denied for function
-- cn_classes" instead of the RLS refusal it is meant to be. A list of five
-- English words is not a secret; the wrong error message is a real bug.
revoke execute on function public.cn_aura(jsonb, text, text)            from public, anon, authenticated;
revoke execute on function public.cn_aura_bonus(jsonb, jsonb, jsonb)    from public, anon, authenticated;
revoke execute on function public.cn_aura_resist(jsonb, jsonb, jsonb)   from public, anon, authenticated;

-- -------------------------------------------------------------------------
-- 4. the snapshot carries the aura
--
-- Spliced from 0019 rather than retyped. The deployment order in this
-- function is load-bearing and has been wrong before.
-- -------------------------------------------------------------------------
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
      -- The aura travels with the unit, like every other stat, because a
      -- card retuned mid-match must not change a match already running.
      'auraKind', c.aura_kind, 'auraClass', c.aura_class, 'auraPct', c.aura_pct,
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

-- -------------------------------------------------------------------------
-- 5. and the exchange reads it
--
-- Spliced from 0020. THE ONLY CHANGE IS THE TWO cn_damage CALLS, which
-- used to pass 0 and 0 for the bonus and the resistance 0018 put in the
-- signature and nothing ever filled. Every rule in the chain -- the parry
-- loop, Lium catching answers, the bloom, the cap -- is untouched.
-- -------------------------------------------------------------------------
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
  v_swings jsonb := '[]'::jsonb;
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
    v_swings := v_swings || jsonb_build_object(
      'k', 'heal', 'by', p_unit, 'at', p_target, 'dmg', v_heal,
      'crit', false, 'counter', false, 'first', false, 'def', false,
      'why', 'mend');

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
    v_swings := v_swings || jsonb_build_object(
      'k', 'hit', 'by', p_unit, 'at', p_target, 'dmg', v_dmg,
      'crit', v_crit, 'counter', false, 'first', false, 'def', false,
      'why', 'tree');
    if v_killed_tgt then
      v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_target, 'at', p_target);
    end if;
    if (v_atk->>'burned')::boolean then
      v_burn_atk := 5; v_atk_hp := v_atk_hp - 5;
      v_swings := v_swings || jsonb_build_object(
        'k', 'burn', 'by', p_unit, 'at', p_unit, 'dmg', 5);
    end if;
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
                             v_crit_counter, true,
                             cn_aura_bonus(v_st, v_tgt, v_atk),
                             cn_aura_resist(v_st, v_tgt, v_atk),
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
      -- 'first' is what tells the cinematic to play this BEFORE the lunge it
      -- is answering, which is the whole of Quick Dagger.
      v_swings := v_swings || jsonb_build_object(
        'k', 'hit', 'by', p_target, 'at', p_unit, 'dmg', v_counter,
        'crit', v_crit_counter, 'counter', true, 'first', true,
        'def', coalesce((v_atk->>'defending')::boolean, false),
        'why', 'quick');
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
        -- 'why' says which rule caught it. Lium catching an answer is not the
        -- same event as a 5% roll coming up, and a caption that calls both of
        -- them "parries" is not narrating, it is labelling.
        v_swings := v_swings || jsonb_build_object(
          'k', 'parry', 'by', v_recv->>'id', 'at', v_strk->>'id',
          'why', case when v_is_counter
                       and coalesce((v_recv->>'parryAll')::boolean, false)
                      then 'all' else 'roll' end);
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
                         v_hit_crit, v_is_counter,
                         cn_aura_bonus(v_st, v_strk, v_recv),
                         cn_aura_resist(v_st, v_strk, v_recv),
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
      v_swings := v_swings || jsonb_build_object(
        'k', 'hit', 'by', v_strk->>'id', 'at', v_recv->>'id', 'dmg', v_hit,
        'crit', v_hit_crit, 'counter', v_is_counter, 'first', false,
        'def', coalesce((v_recv->>'defending')::boolean, false),
        'why', case when v_is_counter then 'counter' else 'strike' end);
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
        v_swings := v_swings || jsonb_build_object(
          'k', 'burn', 'by', v_strk->>'id', 'at', v_strk->>'id', 'dmg', 5);
      end if;
      v_killed_atk := v_atk_hp <= 0;
      v_killed_tgt := v_tgt_hp <= 0;
      -- Recorded HERE rather than counted up at the end, because the order is
      -- the whole point of the list: a cinematic has to know whether somebody
      -- fell before or after the blow that follows.
      if v_killed_tgt then
        v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_target, 'at', p_target);
      end if;
      if v_killed_atk then
        v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_unit, 'at', p_unit);
      end if;
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
    'swings', v_swings,
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
-- 6. THE ROSTER, as section 6 of project_status.md writes it
--
-- The classes go first and on their own, because the trigger above refuses any
-- role that is not one of the five and every row here is currently something
-- else. The numbers follow. Nothing sets rmin, rmax, crmin, crmax, dmin, dmax,
-- flies or royal: all eight are derived, and setting them by hand here would
-- be two sources for one fact.
-- ---------------------------------------------------------------------------
update public.cards set role = case slug
    when 'dereo' then 'royal'
    when 'dione-grifo' then 'knight'
    when 'lium' then 'knight'
    when 'mako' then 'rogue'
    when 'eva' then 'rogue'
    when 'himanta' then 'rogue'
    when 'fey' then 'mage'
    when 'umiro' then 'mage'
    when 'sinie' then 'mage'
    when 'wuzu' then 'flying'
    when 'lumea' then 'flying'
    else role end
 where slug in ('dereo','dione-grifo','lium','mako','eva','himanta',
                'fey','umiro','sinie','wuzu','lumea');

-- Trampling is nowhere in the spec, and the only card that had it is a flier
-- now -- which goes over a tree rather than through it.
update public.cards set tramples = false where tramples;

-- HP, damage, movement, range, name and place in the list. One statement per
-- card so a diff of this file reads as a roster rather than as a matrix.
update public.cards set name='King Dereo', hp=110, power=30, mov=1, range=1, sort=1  where slug='dereo';
update public.cards set                    hp=95,  power=30, mov=1, range=1, sort=4  where slug='dione-grifo';
update public.cards set                    hp=85,  power=35, mov=1, range=1, sort=5  where slug='lium';
update public.cards set                    hp=60,  power=35, mov=2, range=1, sort=6  where slug='mako';
update public.cards set                    hp=80,  power=20, mov=2, range=2, sort=7  where slug='eva';
update public.cards set                    hp=70,  power=25, mov=2, range=1, sort=8  where slug='himanta';
update public.cards set                    hp=85,  power=15, mov=2, range=3, sort=10 where slug='fey';
update public.cards set                    hp=75,  power=25, mov=1, range=2, sort=11 where slug='umiro';
update public.cards set                    hp=65,  power=30, mov=2, range=3, sort=12 where slug='sinie';
update public.cards set                    hp=85,  power=25, mov=3, range=2, sort=18 where slug='wuzu';
update public.cards set                    hp=75,  power=20, mov=4, range=2, sort=19 where slug='lumea';

-- The crown Dereo has carried alone since 0018.
update public.cards
   set aura_kind = 'resist', aura_class = 'knight', aura_pct = 20
 where slug = 'dereo';

-- ---------------------------------------------------------------------------
-- 7. the nine who were only ever words
--
-- INACTIVE, every one. They are on the roster page, they have their sentence
-- in both languages, and they cannot be put in a kingdom until the ability
-- that sentence describes exists. `art_url` is null, which the client draws as
-- the unit's initial -- a missing picture is invisible rather than broken.
-- ---------------------------------------------------------------------------
insert into public.cards
  (slug, name, role, hp, mov, range, power, ability, ability_es,
   accent, art_url, sort, is_active, aura_kind, aura_class, aura_pct)
values
  ('miah', 'Queen Miah', 'royal', 110, 1, 1, 25,
   'The entire team deals slightly (20%) more damage to Mages.',
   'Todo el equipo inflige un leve (20%) daño adicional a Magos.',
   '#c94f9b', null, 2, false, 'bonus', 'mage', 20),

  ('stelaris', 'King Stelaris', 'royal', 120, 1, 1, 30,
   'Grants the team strong (50%) resistance to burn and poison.',
   'Otorga al equipo gran (50%) resistencia a quemadura y veneno.',
   '#2f7fd9', null, 3, false, 'resist_effects', null, 50),

  ('dorme', 'Dorme', 'rogue', 65, 2, 2, 30,
   'Quick Dagger — Always counters before the attacker''s hit lands.',
   'Daga Rápida — Siempre contraataca antes de recibir el golpe.',
   '#8f4f2f', null, 9, false, null, null, null),

  ('ashvar', 'Ashvar', 'mage', 70, 2, 2, 20,
   'Fireball — Burns 2 tiles in a line and deals them 15 damage.',
   'Bola de Fuego — Quema 2 casillas en línea y les inflige 15 de daño.',
   '#e2761b', null, 13, false, null, null, null),

  ('velmor', 'Velmor', 'mage', 70, 2, 2, 35,
   'Cursed Blade — Poisons the target and deals 10 damage.',
   'Espada Maldita — Envenena al objetivo e inflige 10 de daño.',
   '#6b3fa0', null, 14, false, null, null, null),

  ('sarrave', 'Sarrave', 'mage', 80, 1, 1, 15,
   'At the start of their turn, poisons all adjacent tiles.',
   'Al inicio de su turno, envenena todas las casillas adyacentes.',
   '#4f7a3a', null, 15, false, null, null, null),

  ('thalgrim', 'Thalgrim', 'mage', 80, 1, 1, 15,
   'Deals an extra 25 damage if the target is poisoned.',
   'Inflige 25 de daño adicional si el objetivo está envenenado.',
   '#7a6a4f', null, 16, false, null, null, null),

  ('nyxara', 'Nyxara', 'mage', 65, 2, 2, 15,
   'Cursed Body — Heals for 100% of damage dealt.',
   'Cuerpo Maldito — Se cura el 100% del daño infligido.',
   '#a02f5a', null, 17, false, null, null, null),

  ('zephyra', 'Zephyra', 'flying', 65, 4, 1, 20,
   'Cyclone — Stuns the target on hit.',
   'Ciclón — Aturde al objetivo al golpearlo.',
   '#4fb7c9', null, 20, false, null, null, null)

on conflict (slug) do update set
  name = excluded.name, role = excluded.role, hp = excluded.hp,
  mov = excluded.mov, range = excluded.range, power = excluded.power,
  ability = excluded.ability, ability_es = excluded.ability_es,
  accent = excluded.accent, sort = excluded.sort,
  aura_kind = excluded.aura_kind, aura_class = excluded.aura_class,
  aura_pct = excluded.aura_pct;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  -- SCOPED TO THE TWENTY BY NAME. These two read `from public.cards` with no
  -- WHERE when this file shipped, and both came back false on a database that
  -- was perfectly correct: 0001 seeds four placeholder cards with no slug and
  -- no class, 0005 retired them, and they have been in the table ever since.
  -- The count was twenty-four and four rows have never had a class. 0032 gives
  -- them one; this is the check saying what it meant to say.
  (select count(*) from public.cards where slug in (
     'dereo','miah','stelaris','dione-grifo','lium','mako','eva','himanta',
     'dorme','fey','umiro','sinie','ashvar','velmor','sarrave','thalgrim',
     'nyxara','wuzu','lumea','zephyra')) = 20                     as twenty_units,
  (select count(*) from public.cards
    where is_active and slug is not null) = 11                    as eleven_of_them_playable,
  (select count(*) from public.cards
    where slug is not null
      and not (role = any(public.cn_classes()))) = 0              as every_card_has_a_real_class,
  (select hp = 110 and power = 30 and mov = 1 and range = 1 and royal
     from public.cards where slug = 'dereo')                     as dereo_is_the_specs_royal,
  (select dmin = 25 and dmax = 35
     from public.cards where slug = 'dereo')                     as with_the_dice_around_it,
  (select not flies and not tramples
     from public.cards where slug = 'himanta')                   as himanta_walks_now,
  (select flies and not tramples
     from public.cards where slug = 'wuzu')                      as and_wuzu_flies,
  (select count(*) from public.cards where royal) = 3            as three_crowns_exist,
  (select count(*) from public.cards where royal and is_active) = 1
                                                                 as but_only_one_is_playable,
  (select aura_kind = 'resist' and aura_class = 'knight' and aura_pct = 20
     from public.cards where slug = 'dereo')                     as and_it_guards_against_knights;
