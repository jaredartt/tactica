-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0010, 0011 and 0012 first. The last statement prints a row of checks;
--  every column must say true.
-- ===========================================================================
--  0013 - Himanta and Lium, and the answer that comes first
--
--  Two more monsters, and one new rule between them.
--
--    Himanta   A manta that glides. It flies, like Lumea, but it is the
--              opposite kind of flier: slow, heavy, and it reaches two tiles
--              instead of one. Lumea crosses the board; Himanta holds the
--              middle of it.
--
--    Lium      parries. Its answer lands BEFORE the blow it is answering, so
--              if the answer kills, the blow never happens at all. That makes
--              it the one unit you cannot afford to poke: either you finish
--              it in a single stroke, or you leave it alone -- and it is the
--              reason Mako exists, because a thief takes no answer at all.
--
--  parries is a flag on the card, like flies and sneaks before it, so the
--  next duellist is a row and not a code change.
-- ===========================================================================

alter table public.cards add column if not exists parries boolean not null default false;

insert into public.cards
  (slug, name, role, hp, mov, rmin, rmax, crmin, crmax, dmin, dmax,
   burns, heals, flies, sneaks, cures, tramples, parries,
   attack, move, range, ability, accent, art_url, sort, is_active)
values
  ('himanta', 'Himanta', 'Monster', 90, 2, 1, 2, 1, 2, 18, 26,
   false, false, true, false, false, false, false, 22, 2, 2,
   'Glides over everything, and answers at two tiles as readily as at one.',
   '#6d7fc7', 'cards/himanta.webp', 9, true),

  ('lium', 'Lium', 'Monster', 80, 3, 1, 1, 1, 1, 22, 30,
   false, false, false, false, false, false, true, 26, 3, 1,
   'Answers before it is struck. Finish it in one blow, or do not touch it.',
   '#7b6fa8', 'cards/lium.webp', 10, true)

on conflict (slug) do update set
  name = excluded.name, role = excluded.role, hp = excluded.hp, mov = excluded.mov,
  rmin = excluded.rmin, rmax = excluded.rmax, crmin = excluded.crmin, crmax = excluded.crmax,
  dmin = excluded.dmin, dmax = excluded.dmax,
  burns = excluded.burns, heals = excluded.heals, flies = excluded.flies,
  sneaks = excluded.sneaks, cures = excluded.cures, tramples = excluded.tramples,
  parries = excluded.parries,
  attack = excluded.attack, move = excluded.move, range = excluded.range,
  ability = excluded.ability, accent = excluded.accent, art_url = excluded.art_url,
  sort = excluded.sort, is_active = true, updated_at = now();

-- Three lines that ran to three on the card. Two is the budget: a rule you
-- cannot read at a glance is not doing its job.
update public.cards set ability = 'Goes over the trees and over your line. Nothing on the ground stops it.'
 where slug = 'lumea';
update public.cards set ability = 'Reaches two or three tiles, and only the same reach answers back.'
 where slug = 'fey';
update public.cards set ability = 'Sets what it strikes alight. A burning unit loses 5 whenever it swings.'
 where slug = 'dereo';

-- ---------------------------------------------------------------------------
-- 1. the flag travels onto the board with everything else
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
      'dmin', c.dmin, 'dmax', c.dmax,
      'burns', c.burns, 'heals', c.heals, 'burned', false,
      'flies', c.flies, 'sneaks', c.sneaks, 'cures', c.cures, 'tramples', c.tramples,
      'parries', c.parries,
      'accent', c.accent, 'art', c.art_url, 'ability', c.ability,
      'x', vx, 'y', vy, 'moved', false, 'acted', false);
  end loop;
  return v_units;
end $$;

-- ---------------------------------------------------------------------------
-- 2. the exchange, reordered for the one unit that answers first
-- ---------------------------------------------------------------------------
create or replace function public.cn_attack(p_match uuid, p_side text, p_unit text, p_target text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; v_other text; v_st jsonb; u jsonb; e jsonb;
  v_atk jsonb; v_tgt jsonb; v_tree jsonb;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_dist int; v_dmg int := 0; v_heal int := 0;
  v_tgt_hp int; v_atk_hp int; v_counter int := 0;
  v_burn_atk int := 0; v_burn_tgt int := 0; v_new_burn boolean := false;
  v_cured boolean := false;
  v_answers boolean := false; v_parry boolean := false;
  v_killed_tgt boolean := false; v_killed_atk boolean := false;
  v_ally boolean := false; v_foes int := 0; v_mine int := 0; v_win text;
  v_note text;
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
    v_heal := cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int);
    v_tgt_hp := least((v_tgt->>'maxHp')::int, (v_tgt->>'hp')::int + v_heal);
    v_heal := v_tgt_hp - (v_tgt->>'hp')::int;
    v_cured := coalesce((v_atk->>'cures')::boolean, false)
               and coalesce((v_tgt->>'burned')::boolean, false);
    v_note := (v_atk->>'name') || ' mends ' || (v_tgt->>'name') || ' for ' || v_heal || '.';

  elsif v_tree is not null then
    v_dmg := cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int);
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
    v_parry := v_answers and coalesce((v_tgt->>'parries')::boolean, false);

    -- 1. The parry. It happens BEFORE the blow it is answering, which is the
    --    whole of the ability: kill it in one stroke or do not touch it.
    if v_parry then
      v_counter := cn_roll((v_tgt->>'dmin')::int, (v_tgt->>'dmax')::int);
      v_atk_hp := v_atk_hp - v_counter;
      if (v_tgt->>'burned')::boolean then
        v_burn_tgt := 5; v_tgt_hp := v_tgt_hp - 5;
      end if;
      v_killed_atk := v_atk_hp <= 0;
      v_killed_tgt := v_tgt_hp <= 0;
    end if;

    -- 2. The blow, unless the answer already finished the attacker.
    if not v_killed_atk then
      v_dmg := cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int);
      v_tgt_hp := v_tgt_hp - v_dmg;
      v_killed_tgt := v_tgt_hp <= 0;

      -- 3. The ordinary counter, for everyone who does not parry.
      if v_answers and not v_parry and not v_killed_tgt then
        v_counter := cn_roll((v_tgt->>'dmin')::int, (v_tgt->>'dmax')::int);
        v_atk_hp := v_atk_hp - v_counter;
        if (v_tgt->>'burned')::boolean then
          v_burn_tgt := 5;
          v_tgt_hp := v_tgt_hp - 5;
          v_killed_tgt := v_tgt_hp <= 0;
        end if;
      end if;

      if (v_atk->>'burned')::boolean then v_burn_atk := 5; v_atk_hp := v_atk_hp - 5; end if;
      v_killed_atk := v_atk_hp <= 0;
      v_new_burn := (v_atk->>'burns')::boolean and not v_killed_tgt;
    end if;

    if v_parry and v_dmg = 0 then
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
    'cured', v_cured, 'parry', v_parry, 'tree', (v_tree is not null)));

  v_st := state_log(v_st, v_note);
  if v_cured then v_st := state_log(v_st, (v_tgt->>'name') || ' stops burning.'); end if;
  if v_new_burn then v_st := state_log(v_st, (v_tgt->>'name') || ' is burning.'); end if;
  if v_counter > 0 then
    v_st := state_log(v_st, (v_tgt->>'name')
      || case when v_parry then ' answers first for ' else ' counters for ' end || v_counter
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
    if u->>'owner' = p_side then v_mine := v_mine + 1; else v_foes := v_foes + 1; end if;
  end loop;
  if v_foes = 0 then v_win := p_side;
  elsif v_mine = 0 then v_win := v_other; end if;

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
-- 3. the bot has to know what a parry costs
--
-- Without this it treats a killing blow as free, because ordinarily a dead
-- defender cannot answer. Against Lium that is exactly backwards.
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
end $$;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.cards where is_active) = 10             as roster_is_ten,
  (select flies    from public.cards where slug = 'himanta')           as himanta_flies,
  (select parries  from public.cards where slug = 'lium')              as lium_parries,
  (select count(*) = 0 from public.cards
    where is_active and (art_url is null or role = ''))                as all_ten_are_dressed,
  (select max(length(ability)) from public.cards where is_active) <= 78 as every_rule_fits_the_card,
  (select 'parries' = any(
     select jsonb_object_keys(e)
       from jsonb_array_elements(
              public.cn_army(public.cn_fresh_map(), 'host', array['lium','himanta','mako','eva'])
            ) e))                                                     as flag_reaches_the_board;
