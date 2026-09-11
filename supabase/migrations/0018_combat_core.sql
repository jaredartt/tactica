-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0001 through 0017 first. The last statement prints a row of checks;
--  every column must say true.
-- ===========================================================================
--  0018 - the combat core
--
--  Phase A of the battle rework. Five things change, and they change together
--  because each one only makes sense alongside the others:
--
--    1. A counter is no longer a second full attack. It lands for HALF. That
--       is what lets a counter happen EVERY time the defender can reach back,
--       instead of the old "only if it survives and only once" -- trading
--       blows is now the normal case, not a punishment.
--    2. Anyone can parry, 5% of the time. A parry blocks the blow completely
--       and answers for half, and that answer can itself be parried. The chain
--       is capped at 8 exchanges so it always terminates.
--    3. Anyone can crit, 5% of the time, for +50%. Crits ride on attacks,
--       counters, and the counter that follows a parry.
--    4. Damage is a single number, plus or minus five. A 30-power unit rolls
--       25-35. The card shows 30, not "25-35" -- the spread is texture, not a
--       decision, and a player should not have to read two numbers to compare
--       two units.
--    5. Losing your royal loses the match, and a kingdom must hold exactly
--       one. The king is the game, not a big unit that happens to be in it.
--
--  Heals are outside all of it: they never crit, are never parried, and never
--  draw a counter. Mending is not an exchange.
--
--  Passives are outside the parry rule too. Only attacks and abilities can be
--  parried -- a passive is not a blow being aimed, so there is nothing to read
--  and nothing to catch. Lium's answer-first is a passive, and lands through
--  a parry for that reason.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. what a card now carries
--
-- `power` is the single number. dmin/dmax stay, because every roll and every
-- test rig in the project speaks in them -- they are now DERIVED from power
-- rather than authored, which is what makes "a single number" true at the
-- card level without rewriting the board.
-- ---------------------------------------------------------------------------
alter table public.cards add column if not exists royal      boolean not null default false;
alter table public.cards add column if not exists parry_all  boolean not null default false;
alter table public.cards add column if not exists power      int;
alter table public.cards add column if not exists parry_pct  int not null default 5;
alter table public.cards add column if not exists crit_pct   int not null default 5;

do $$ begin
  begin
    alter table public.cards add constraint cards_power_check
      check (power is null or (power >= 0 and power <= 999));
  exception when duplicate_object then null; end;
  begin
    alter table public.cards add constraint cards_parry_pct_check
      check (parry_pct between 0 and 100);
  exception when duplicate_object then null; end;
  begin
    alter table public.cards add constraint cards_crit_pct_check
      check (crit_pct between 0 and 100);
  exception when duplicate_object then null; end;
end $$;

-- The midpoint of the old band becomes the new single number, so nothing on
-- the board shifts in expectation -- only the shape of the spread does.
update public.cards set power = round((dmin + dmax) / 2.0)::int where power is null;

-- ...and then the band is regenerated from it. Floored at zero so a mender
-- with power 7 rolls 2-12 rather than -3-12.
create or replace function public.cn_spread() returns int
language sql immutable as $$ select 5 $$;

update public.cards
   set dmin = greatest(0, power - cn_spread()),
       dmax = power + cn_spread(),
       updated_at = now()
 where power is not null;

-- ---------------------------------------------------------------------------
-- 2. the royal
--
-- Dereo is the roster's King Dereo. He is the only crown on the board today,
-- which makes "exactly one royal per kingdom" a forced pick until Queen Miah
-- and King Stelaris arrive with the roster rework -- they need art before they
-- can be added, and the rule has to exist before they do or every deck saved
-- in the meantime would be illegal the day they land.
-- ---------------------------------------------------------------------------
update public.cards set royal = true, updated_at = now() where slug = 'dereo';

-- Lium is the one who is better at this than everyone. Doubled rates, and he
-- catches any answer-to-a-parry aimed at him, which is what makes attacking
-- into him a bad idea rather than an unlucky one.
update public.cards
   set parry_pct = 10, crit_pct = 10, parry_all = true, updated_at = now()
 where slug = 'lium';

-- ---------------------------------------------------------------------------
-- 3. the dice
--
-- Both of these read a database-scoped escape hatch first. A suite that cannot
-- pin a 5% roll either never exercises the parry or fails one run in twenty,
-- and both are worse than a setting nothing in production ever sets. Same
-- pattern as cn.first_side in 0017.
-- ---------------------------------------------------------------------------
create or replace function public.cn_chance(p_pct int, p_kind text)
returns boolean language plpgsql volatile as $$
declare v_forced text;
begin
  -- A certainty is not a roll, so the hatch does not reach it: a unit at 0%
  -- never parries and a unit at 100% always does, whatever the setting says.
  -- That is what lets one test force the dice for the board while still
  -- standing a unit up that does not take part.
  if coalesce(p_pct, 0) <= 0 then return false; end if;
  if p_pct >= 100 then return true; end if;
  v_forced := nullif(current_setting('cn.force_' || p_kind, true), '');
  if v_forced = 'always' then return true; end if;
  if v_forced = 'never'  then return false; end if;
  return random() * 100 < p_pct;
end $$;

create or replace function public.cn_parry_cap() returns int
language sql immutable as $$ select 8 $$;

-- The one place damage is multiplied, in the one order that is correct.
--
--   base roll -> crit -> counter -> attacker bonuses -> defender resists
--   -> defending -> round
--
-- Crit before the counter halving so a critical counter is 75% of a full blow
-- and not 50% of a crit -- the same number either way, but this order is the
-- one the log reads in. Bonuses multiply BEFORE resists so a 20% bonus and a
-- 20% resist do not cancel exactly; they are not the same kind of thing and
-- should not annihilate. p_bonus and p_resist are fractions (0.2, not 20), and
-- are the hook the royal passives and the class resistances will hang on --
-- nothing passes anything but zero yet.
create or replace function public.cn_damage(
  p_base int, p_crit boolean, p_counter boolean,
  p_bonus numeric default 0, p_resist numeric default 0,
  p_defending boolean default false)
returns int language sql immutable as $$
  select greatest(0, round(
    p_base::numeric
    * case when p_crit      then 1.5 else 1 end
    * case when p_counter   then 0.5 else 1 end
    * (1 + coalesce(p_bonus, 0))
    * (1 - coalesce(p_resist, 0))
    * case when p_defending then 0.5 else 1 end
  )::int)
$$;

-- ---------------------------------------------------------------------------
-- 4. the flags travel onto the board
--
-- Spliced from 0014, not rewritten: the deployment order in here is load-
-- bearing and has been wrong before.
-- ---------------------------------------------------------------------------
create or replace function public.cn_army(p_state jsonb, p_side text, p_deck text[])
returns jsonb language plpgsql as $$
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

  for i in 0 .. (v_h - 1) / 2 loop
    if 2 * i + 1 < v_h then v_ys := v_ys || (2 * i + 1); end if;
  end loop;
  for i in 0 .. (v_h - 1) / 2 loop
    if 2 * i < v_h then v_ys := v_ys || (2 * i); end if;
  end loop;

  if p_side = 'host'
    then for i in 0 .. (v_w / 2 - 1)            loop v_xs := v_xs || i; end loop;
    else for i in reverse (v_w - 1) .. (v_w / 2) loop v_xs := v_xs || i; end loop;
  end if;

  for i in 1 .. deck_size() loop
    select * into c from public.cards where slug = p_deck[i];
    if c.id is null then raise exception 'unknown card %', p_deck[i]; end if;

    v_done := false;
    foreach vx in array v_xs loop
      foreach vy in array v_ys loop
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
end $$;

-- ---------------------------------------------------------------------------
-- 5. a kingdom needs its crown
--
-- Enforced in set_deck so a bad deck cannot be saved, AND in deck_of so a deck
-- saved before this migration -- or one whose royal is retired later -- falls
-- back rather than deploying a crownless army into a rule that would then
-- never end the match.
-- ---------------------------------------------------------------------------
create or replace function public.deck_royals(p_deck text[]) returns int
language sql stable as $$
  select count(*)::int from public.cards
   where is_active and royal and slug = any(coalesce(p_deck, '{}'::text[]))
$$;

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

  v_n := deck_royals(p_deck);
  if v_n = 0 then raise exception 'a kingdom needs a royal'; end if;
  if v_n > 1 then raise exception 'a kingdom has exactly one royal'; end if;

  update public.profiles set deck = p_deck where id = v_uid;
  return p_deck;
end $$;

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
  if deck_royals(v_deck) <> 1 then return default_deck(); end if;
  return v_deck;
end $$;

-- The bot draws fresh every time, so practice is never the same shape twice --
-- but it obeys the same rule a player does: one crown, no more.
create or replace function public.random_deck() returns text[]
language sql volatile security definer set search_path = public as $$
  select array_agg(slug) from (
    (select slug from public.cards
      where is_active and slug is not null and royal
      order by random() limit 1)
    union all
    (select slug from public.cards
      where is_active and slug is not null and not royal
      order by random() limit (deck_size() - 1))
  ) s
$$;

-- Spliced from 0008, one line changed.
create or replace function public.create_bot_match(p_level int)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_name text; v_st jsonb; m public.matches;
  v_deck text[]; v_lvl int := greatest(1, least(3, coalesce(p_level, 2)));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username into v_name from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;

  v_deck := random_deck();

  v_st := cn_fresh_map();
  v_st := jsonb_set(v_st, '{ready,guest}', 'true'::jsonb);
  v_st := state_log(v_st, v_name || ' spars with ' || bot_name(v_lvl) || '.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline, bot, ranked)
  values
    (gen_match_code(), v_uid, v_name, null, bot_name(v_lvl),
     'deploying', v_st, now() + interval '90 seconds', v_lvl, false)
  returning * into m;

  perform cn_open_deploy(m.id, m.state, v_uid, null, v_deck);
  insert into public.match_presence (match_id, user_id, side)
  values (m.id, v_uid, 'host') on conflict (match_id, user_id) do update set seen_at = now();
  return m;
end $$;

-- ---------------------------------------------------------------------------
-- 6. the exchange
--
-- Spliced from 0014. Everything outside the "else" branch -- the target
-- lookup, the reach checks, mending, trees, the rebuild of the unit list --
-- is unchanged. The fight itself is new.
--
-- The chain is one uniform loop. Each pass is one swing: the receiver either
-- parries it (no damage, and becomes the swinger for a half-damage answer) or
-- takes it. A blow that lands draws the ordinary counter; a COUNTER that lands
-- ends the exchange, which is what stops two units trading forever. The cap is
-- a second, unconditional stop -- a chain of parries is the only thing that
-- can reach it, and 8 swings is already a story worth watching.
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
                             v_crit_counter, true);
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
                         v_hit_crit, v_is_counter);
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
end $$;

-- ---------------------------------------------------------------------------
-- 7. who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.random_deck()                     from public, anon, authenticated;
grant  execute on function public.cn_chance(int, text)              to authenticated;
grant  execute on function public.cn_damage(int, boolean, boolean, numeric, numeric, boolean)
                                                                    to authenticated;
grant  execute on function public.cn_parry_cap()                    to authenticated;
grant  execute on function public.cn_spread()                       to authenticated;
grant  execute on function public.deck_royals(text[])               to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.cards where is_active and royal) = 1     as one_crown_so_far,
  (select count(*) from public.cards
    where is_active and (dmax - dmin) <> 2 * cn_spread()
      and dmin > 0) = 0                                                 as every_card_is_one_number,
  (select count(*) from public.cards where is_active and power is null) = 0
                                                                        as and_carries_it,
  public.cn_parry_cap() = 8                                             as the_chain_terminates,
  public.cn_damage(30, false, false) = 30                               as a_plain_blow_is_itself,
  public.cn_damage(30, true,  false) = 45                               as a_crit_is_half_again,
  public.cn_damage(30, false, true)  = 15                               as a_counter_is_half,
  public.cn_damage(30, true,  true)  = 23                               as and_a_critical_counter_both,
  public.cn_damage(30, false, false, 0, 0, true) = 15                   as defending_halves_it,
  (select parry_pct from public.cards where slug = 'lium') = 10         as lium_is_better_at_it;
