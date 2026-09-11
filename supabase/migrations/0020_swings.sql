-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0019 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0020 - the exchange, blow by blow
--
--  Phase C wants to SHOW a fight rather than summarise it: two units enlarged,
--  a lunge, a parry, an answer, a caption box saying which rule fired and why.
--  Everything it needs already happens inside cn_attack -- the parry chain
--  swings back and forth up to eight times and each swing knows whether it was
--  a crit, a counter, or caught by Lium rather than by a roll -- and then all
--  of it is thrown away, and `fx` reports the sums.
--
--  Sums cannot be un-added. `dmg 30, counter 45, parries 2, chain 4` has many
--  fights behind it and the client would have to guess which; a cinematic
--  built on that guess would narrate blows that never landed. So the swings
--  are now kept, in the order they happened, and go out on `fx.swings`.
--
--  Nothing about the RULES changes here. No number is computed differently, no
--  branch is taken differently, and the existing fx fields are all still
--  written exactly as they were -- which is why 09_combat.sql and 10_board.sql
--  must still pass untouched. This migration only writes down what the
--  function was already deciding.
--
--  cn_attack below is the 0019 definition with the recording spliced in. It
--  was copied out of 0019 rather than retyped: deploy_unit lost its swap
--  behaviour once by being reconstructed from memory, and 330 lines of combat
--  rules is not the place to find out whether that lesson took.
--
--  A swing is:
--    k       'hit' | 'parry' | 'burn' | 'down' | 'heal'
--    by,at   unit ids (a tree's id, where the target is a tree)
--    dmg     what it took off, for hit/heal/burn
--    crit    the 5% roll came up
--    counter this swing was an answer, so it was halved
--    def     the receiver had a guard up, so it was halved again
--    first   this landed BEFORE the blow it answers (Quick Dagger, and only
--            Quick Dagger)
--    why     'strike' | 'counter' | 'quick' | 'tree' | 'mend' for a hit,
--            'roll' | 'all' for a parry -- Lium catching an answer is not the
--            same event as a 5%% roll and the caption should not call it one
-- ===========================================================================

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
--  the checks
-- ---------------------------------------------------------------------------
select
  (select count(*) = 1 from pg_proc where proname = 'cn_attack') as cn_attack_there,
  (select prosecdef from pg_proc where proname = 'cn_attack')    as still_definer,
  (select pg_get_function_identity_arguments(oid)
     = 'p_match uuid, p_side text, p_unit text, p_target text'
   from pg_proc where proname = 'cn_attack')                     as same_signature;
