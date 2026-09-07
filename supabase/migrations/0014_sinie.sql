-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0010 through 0013 first. The last statement prints a row of checks;
--  every column must say true.
-- ===========================================================================
--  0014 - Sinie, and the mend that does not choose
--
--  Every healer so far mends one ally. Sinie blooms: the roll is spent on
--  EVERY ally standing in her reach, not just the one you clicked. She is
--  frail and hits for almost nothing, so she is never the answer to a fight
--  -- she is the reason to keep three units within two tiles of each other,
--  which is the exact opposite of what Dereo and Fey want you to do.
--
--  One roll, not one per ally: a lucky roll should be lucky once.
-- ===========================================================================

alter table public.cards add column if not exists blooms boolean not null default false;

insert into public.cards
  (slug, name, role, hp, mov, rmin, rmax, crmin, crmax, dmin, dmax,
   burns, heals, flies, sneaks, cures, tramples, parries, blooms,
   attack, move, range, ability, accent, art_url, sort, is_active)
values
  ('sinie', 'Sinie', 'Seer', 60, 2, 1, 2, 1, 1, 4, 10,
   false, true, false, false, false, false, false, true, 7, 2, 2,
   'Mends every ally within reach at once, for the same roll.',
   '#8f86c9', 'cards/sinie.webp', 11, true)

on conflict (slug) do update set
  name = excluded.name, role = excluded.role, hp = excluded.hp, mov = excluded.mov,
  rmin = excluded.rmin, rmax = excluded.rmax, crmin = excluded.crmin, crmax = excluded.crmax,
  dmin = excluded.dmin, dmax = excluded.dmax,
  burns = excluded.burns, heals = excluded.heals, flies = excluded.flies,
  sneaks = excluded.sneaks, cures = excluded.cures, tramples = excluded.tramples,
  parries = excluded.parries, blooms = excluded.blooms,
  attack = excluded.attack, move = excluded.move, range = excluded.range,
  ability = excluded.ability, accent = excluded.accent, art_url = excluded.art_url,
  sort = excluded.sort, is_active = true, updated_at = now();

-- ---------------------------------------------------------------------------
-- 1. the flag travels onto the board
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
      'parries', c.parries, 'blooms', c.blooms,
      'accent', c.accent, 'art', c.art_url, 'ability', c.ability,
      'x', vx, 'y', vy, 'moved', false, 'acted', false);
  end loop;
  return v_units;
end $$;

-- ---------------------------------------------------------------------------
-- 2. mending, for one ally or for all of them
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
  v_bloom jsonb := '[]'::jsonb; v_d2 int; v_got int; v_heal_roll int := 0;
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
    'tree', (v_tree is not null)));

  v_st := state_log(v_st, v_note);
  if jsonb_array_length(v_bloom) > 0 then
    v_st := state_log(v_st, 'The bloom spreads -- '
      || jsonb_array_length(v_bloom) || ' more mended.');
  end if;
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
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.cards where is_active) = 11              as roster_is_eleven,
  (select blooms from public.cards where slug = 'sinie')                as sinie_blooms,
  (select heals  from public.cards where slug = 'sinie')                as and_mends,
  (select count(*) = 0 from public.cards
    where is_active and (art_url is null or role = ''))                 as all_of_them_dressed,
  (select max(length(ability)) from public.cards where is_active) <= 78 as every_rule_fits_the_card;
