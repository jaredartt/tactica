-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  The last statement prints a row of checks. Every column must say true.
-- ===========================================================================
--  0007 — an opponent that is not a person, and a ladder you have to opt into
--
--  THE REFACTOR THAT MAKES THE BOT POSSIBLE. submit_move and submit_attack
--  each did two jobs: work out whether you are allowed to be asking, and then
--  apply the rules. Those are now separate functions. cn_move and cn_attack
--  hold every rule and know nothing about who is calling; submit_move and
--  submit_attack are thin shells that check it is you, that it is your turn,
--  that your clock has not run out, and then hand over.
--
--  The bot calls the same cn_move and cn_attack. Not a copy of them -- the
--  same ones. So it cannot walk through a tree, shoot round one, hit at a
--  range its card does not have, or take a counter it should have taken, and
--  when you change a rule the bot changes with it. That is the whole reason
--  it is worth doing this way round rather than teaching a second brain the
--  rules a second time.
--
--  It plays one action per call, so you watch it think rather than seeing its
--  whole turn arrive at once. Any client may ask for the next step; the
--  function refuses unless it really is a bot match and really is the bot's
--  turn, which is the same shape as the turn clock.
--
--  RANKED IS NOW A PLACE YOU GO. Hosting a room or joining a code is off the
--  record entirely -- no LP, no hidden rating, not counted. Only the queue
--  pairs you by strength and moves your number.
-- ===========================================================================

alter table public.matches add column if not exists bot    int;
alter table public.matches add column if not exists ranked boolean not null default false;

-- ---------------------------------------------------------------------------
-- 1. the rules, with nobody's name on them
-- ---------------------------------------------------------------------------
create or replace function public.cn_move(p_match uuid, p_side text, p_unit text, p_x int, p_y int)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; v_st jsonb; u jsonb; v_me jsonb;
  v_out jsonb := '[]'::jsonb; v_reach text[];
begin
  select * into m from public.matches where id = p_match for update;
  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if v_me->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
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

create or replace function public.submit_move(p_match uuid, p_unit text, p_x int, p_y int)
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
  return cn_move(p_match, v_side, p_unit, p_x, p_y);
end $$;

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

    if (v_atk->>'burned')::boolean then v_burn_atk := 5; v_atk_hp := v_atk_hp - 5; end if;
    v_killed_atk := v_atk_hp <= 0;
    v_new_burn := (v_atk->>'burns')::boolean and not v_killed_tgt;

    v_note := (v_atk->>'name') || ' hits ' || (v_tgt->>'name') || ' for ' || v_dmg
              || case when v_killed_tgt and v_burn_tgt = 0 then ' -- destroyed.' else '.' end;
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
  if v_new_burn then v_st := state_log(v_st, (v_tgt->>'name') || ' is burning.'); end if;
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
    if u->>'owner' = p_side then v_mine := v_mine + 1; else v_foes := v_foes + 1; end if;
  end loop;
  if v_foes = 0 then v_win := p_side;
  elsif v_mine = 0 then v_win := v_other; end if;

  if v_win is not null then
    -- Only the queue moves anyone's number. A room you opened yourself, or a
    -- match against the bot, is off the record entirely.
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

create or replace function public.submit_attack(p_match uuid, p_unit text, p_target text)
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
  return cn_attack(p_match, v_side, p_unit, p_target);
end $$;

-- resign and claim_win were rating unconditionally too
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
  if m.ranked then perform finish_match(m.id, v_win, 'resign'); end if;

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

create or replace function public.claim_win(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; v_side text; v_other text; v_n int;
  v_their_id uuid; v_seen timestamptz; v_busy boolean := false; u jsonb; st jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  if m.bot is not null then raise exception 'the bot does not go anywhere'; end if;

  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  v_other := case when v_side = 'host' then 'guest' else 'host' end;

  v_n := coalesce((m.state->'idle'->>v_other)::int, 0);
  if v_n < 3 then raise exception 'they have not missed three turns yet'; end if;

  for u in select * from jsonb_array_elements(m.state->'units') loop
    if u->>'owner' = v_other and ((u->>'moved')::boolean or (u->>'acted')::boolean) then
      v_busy := true;
    end if;
  end loop;
  if v_busy then raise exception 'they are playing right now'; end if;

  if v_n < 6 then
    v_their_id := case when v_other = 'host' then m.host_id else m.guest_id end;
    select seen_at into v_seen from public.match_presence
     where match_id = p_match and user_id = v_their_id;
    if v_seen is not null and v_seen > now() - presence_grace() then
      raise exception 'they are still connected — you can claim this once they drop, or after six missed turns';
    end if;
  end if;

  if m.ranked then perform finish_match(m.id, v_side, 'abandon'); end if;
  st := jsonb_set(m.state, '{winner}', to_jsonb(v_side));
  st := state_log(st,
        case when v_other = 'host' then m.host_name else m.guest_name end
        || ' abandoned the match. '
        || case when v_side = 'host' then m.host_name else m.guest_name end || ' wins.');

  update public.matches
     set state = st, status = 'finished', winner = v_side,
         turn_deadline = null, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

-- ---------------------------------------------------------------------------
-- 2. the bot
--
-- It has no account and never will. matches.guest_id stays null and
-- matches.bot holds the difficulty, so side_of() gives the guest seat to
-- nobody, join_match cannot take it, and nothing else in the system needs a
-- fake person walking around in the profiles table.
-- ---------------------------------------------------------------------------
create or replace function public.bot_name(p_level int) returns text
language sql immutable as $$
  select case p_level when 1 then 'CALM' when 2 then 'SHARP' else 'RUTHLESS' end
$$;

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

  -- Its four are drawn fresh each time, so practice is never the same shape
  -- twice and you meet every card eventually.
  select array_agg(slug) into v_deck
  from (select slug from public.cards where is_active and slug is not null
         order by random() limit deck_size()) s;

  v_st := cn_fresh_map();
  v_st := cn_place(v_st, 'host',  deck_of(v_uid));
  v_st := cn_place(v_st, 'guest', v_deck);
  -- It has no deploy screen to sit in front of, so it is ready from the start.
  v_st := jsonb_set(v_st, '{ready,guest}', 'true'::jsonb);
  v_st := state_log(v_st, v_name || ' spars with ' || bot_name(v_lvl) || '.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline, bot, ranked)
  values
    (gen_match_code(), v_uid, v_name, null, bot_name(v_lvl),
     'deploying', v_st, now() + interval '90 seconds', v_lvl, false)
  returning * into m;

  insert into public.match_presence (match_id, user_id, side)
  values (m.id, v_uid, 'host') on conflict (match_id, user_id) do update set seen_at = now();
  return m;
end $$;

-- One action per call, so you watch it play instead of finding its whole turn
-- already done. Everything it does goes through cn_move and cn_attack -- the
-- same two functions your clicks go through -- so it is bound by every rule
-- you are, and a rule change moves it too.
create or replace function public.bot_step(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; st jsonb; v_lvl int; v_noise numeric;
  u jsonb; t jsonb;
  v_tiles text[]; v_tile text; vx int; vy int; v_first boolean;
  v_best numeric := 0; v_bu text; v_bx int; v_by int; v_bt text;
  v_pos numeric; v_base numeric; v_act numeric;
  v_d int; v_dmg numeric; v_ctr numeric; v_near int; v_thr int;
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
      v_tiles := v_tiles || cn_reach(st, (u->>'x')::int, (u->>'y')::int, (u->>'mov')::int);
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
      v_pos := - abs(v_near - (u->>'rmax')::int) * 5.0;
      if v_lvl >= 3 then v_pos := v_pos - v_thr * 9.0; end if;

      if v_first then v_base := v_pos; v_first := false; end if;

      -- ---- moving there and doing nothing else ---------------------------
      v_noise := random() * (case v_lvl when 1 then 220 when 2 then 90 else 15 end);
      if v_pos - v_base + v_noise > v_best then
        v_best := v_pos - v_base + v_noise;
        v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := null;
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
          v_act := least(v_dmg, (t->>'hp')::int) * 10.0;
          if v_dmg >= (t->>'hp')::int then
            v_act := v_act + 400 + (t->>'maxHp')::int;          -- a kill is worth a lot
          else
            if (u->>'burns')::boolean and not (t->>'burned')::boolean then
              v_act := v_act + 25;
            end if;
            if v_d >= (t->>'crmin')::int and v_d <= (t->>'crmax')::int then
              v_ctr := ((t->>'dmin')::int + (t->>'dmax')::int) / 2.0;
              -- the easy one does not think about what comes back
              v_act := v_act - v_ctr * (case v_lvl when 1 then 3.0 else 12.0 end);
              if v_ctr >= (u->>'hp')::int then
                v_act := v_act - 500 - (u->>'maxHp')::int;
              end if;
            end if;
          end if;
        end if;

        v_noise := random() * (case v_lvl when 1 then 220 when 2 then 90 else 15 end);
        if v_pos + v_act - v_base + v_noise > v_best then
          v_best := v_pos + v_act - v_base + v_noise;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := t->>'id';
        end if;
      end loop;
    end loop;
  end loop;

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
-- 3. the ranked queue
--
-- One row per player, forever -- `active` says whether they are looking right
-- now. That is deliberate: there is no DELETE anywhere in this file, and with
-- a row per account the table cannot grow past the number of accounts.
--
-- The window each player will accept widens the longer they have waited, so
-- the first minute looks for someone genuinely near you and after that it
-- stops being fussy. With a handful of players that matters more than
-- precision does.
-- ---------------------------------------------------------------------------
create table if not exists public.ranked_queue (
  user_id   uuid primary key references public.profiles(id) on delete cascade,
  username  text not null,
  mmr       int not null,
  active    boolean not null default true,
  joined_at timestamptz not null default now(),
  seen_at   timestamptz not null default now()
);
alter table public.ranked_queue enable row level security;
revoke all on public.ranked_queue from anon, authenticated;   -- functions only

create or replace function public.queue_stale() returns interval
language sql immutable as $$ select interval '25 seconds' $$;

create or replace function public.cn_queue_window(p_joined timestamptz)
returns int language sql stable as $$
  select 120 + (40 * extract(epoch from now() - p_joined))::int
$$;

create or replace function public.leave_ranked() returns void
language sql security definer set search_path = public as $$
  update public.ranked_queue set active = false where user_id = auth.uid();
$$;

-- Called every couple of seconds while the queue screen is open. It keeps you
-- in the queue, looks for someone, and tells you where you stand.
create or replace function public.ranked_tick()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_name text; v_mmr int; v_joined timestamptz;
  v_them public.ranked_queue; m public.matches; v_st jsonb;
  v_found uuid; v_waiting int;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username into v_name from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;

  -- Already paired? Whoever created the match returns it below; the other
  -- player finds it here, which is why no invitation has to change hands.
  select id into v_found from public.matches
   where ranked and status in ('deploying', 'active')
     and (host_id = v_uid or guest_id = v_uid)
     and created_at > now() - interval '3 minutes'
   order by created_at desc limit 1;
  if v_found is not null then
    update public.ranked_queue set active = false where user_id = v_uid;
    return jsonb_build_object('match', v_found, 'waiting', 0);
  end if;

  select coalesce(mmr, 1000) into v_mmr from public.player_rating where user_id = v_uid;
  v_mmr := coalesce(v_mmr, 1000);

  insert into public.ranked_queue (user_id, username, mmr, active, joined_at, seen_at)
  values (v_uid, v_name, v_mmr, true, now(), now())
  on conflict (user_id) do update
    set seen_at = now(), active = true, username = excluded.username, mmr = excluded.mmr,
        -- rejoining after a break restarts the clock; a tick does not
        joined_at = case when public.ranked_queue.active
                          and public.ranked_queue.seen_at > now() - queue_stale()
                         then public.ranked_queue.joined_at else now() end
  returning joined_at into v_joined;

  -- skip locked, not a plain lock: if they are picking us at this instant,
  -- stepping over them means one of the two ticks wins and neither waits.
  select * into v_them from public.ranked_queue q
   where q.user_id <> v_uid and q.active and q.seen_at > now() - queue_stale()
     and abs(q.mmr - v_mmr) <= greatest(cn_queue_window(v_joined),
                                        cn_queue_window(q.joined_at))
   order by abs(q.mmr - v_mmr), q.joined_at
   limit 1 for update skip locked;

  select count(*) into v_waiting from public.ranked_queue q
   where q.active and q.seen_at > now() - queue_stale();

  if v_them.user_id is null then
    return jsonb_build_object('match', null, 'waiting', v_waiting);
  end if;

  -- The one who has waited longer gets the first move.
  v_st := cn_fresh_map();
  if v_them.joined_at <= v_joined then
    v_st := cn_place(v_st, 'host',  deck_of(v_them.user_id));
    v_st := cn_place(v_st, 'guest', deck_of(v_uid));
    insert into public.matches
      (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline, ranked)
    values (gen_match_code(), v_them.user_id, v_them.username, v_uid, v_name,
            'deploying', state_log(v_st, 'Ranked match found.'), now() + interval '90 seconds', true)
    returning * into m;
  else
    v_st := cn_place(v_st, 'host',  deck_of(v_uid));
    v_st := cn_place(v_st, 'guest', deck_of(v_them.user_id));
    insert into public.matches
      (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline, ranked)
    values (gen_match_code(), v_uid, v_name, v_them.user_id, v_them.username,
            'deploying', state_log(v_st, 'Ranked match found.'), now() + interval '90 seconds', true)
    returning * into m;
  end if;

  update public.matches set state = state_log(state, 'Place your units, then press Ready.')
   where id = m.id;
  update public.ranked_queue set active = false where user_id in (v_uid, v_them.user_id);
  insert into public.match_presence (match_id, user_id, side) values
    (m.id, m.host_id, 'host'), (m.id, m.guest_id, 'guest')
  on conflict (match_id, user_id) do update set seen_at = now();

  return jsonb_build_object('match', m.id, 'waiting', 0);
end $$;

-- ---------------------------------------------------------------------------
-- 4. rematch
--
-- A rematch is never ranked, whoever you are playing. You picked this
-- opponent, and two people who like each other could otherwise trade wins all
-- afternoon. Against the bot there is nobody to agree with, so it just starts.
-- ---------------------------------------------------------------------------
create or replace function public.request_rematch(p_match uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare m public.matches; v_side text; v_st jsonb; nm public.matches; v_new uuid;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'finished' then raise exception 'that match is still running'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.next_match_id is not null then return m.next_match_id; end if;

  if m.bot is not null then
    select id into v_new from public.create_bot_match(m.bot);
    update public.matches set next_match_id = v_new where id = p_match;
    return v_new;
  end if;

  if v_side = 'host'
    then update public.matches set rematch_host  = true where id = p_match;
    else update public.matches set rematch_guest = true where id = p_match;
  end if;

  select * into m from public.matches where id = p_match;
  if not (m.rematch_host and m.rematch_guest) then return null; end if;

  v_st := cn_fresh_map();
  v_st := cn_place(v_st, 'host',  deck_of(m.guest_id));
  v_st := cn_place(v_st, 'guest', deck_of(m.host_id));
  v_st := state_log(v_st, 'Rematch on new ground. ' || m.guest_name || ' moves first.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline, ranked)
  values
    (gen_match_code(), m.guest_id, m.guest_name, m.host_id, m.host_name,
     'deploying', v_st, now() + interval '90 seconds', false)
  returning * into nm;

  insert into public.match_presence (match_id, user_id, side) values
    (nm.id, nm.host_id, 'host'), (nm.id, nm.guest_id, 'guest')
  on conflict (match_id, user_id) do update set seen_at = now();

  update public.matches set next_match_id = nm.id where id = p_match;
  return nm.id;
end $$;

-- ---------------------------------------------------------------------------
-- 5. grants
-- ---------------------------------------------------------------------------
revoke execute on function public.cn_move(uuid, text, text, int, int)   from public, anon, authenticated;
revoke execute on function public.cn_attack(uuid, text, text, text)     from public, anon, authenticated;
revoke execute on function public.cn_queue_window(timestamptz)          from public, anon, authenticated;
revoke execute on function public.queue_stale()                         from public, anon, authenticated;
grant  execute on function public.create_bot_match(int) to authenticated;
grant  execute on function public.bot_step(uuid)        to authenticated;
grant  execute on function public.bot_name(int)         to authenticated;
grant  execute on function public.ranked_tick()         to authenticated;
grant  execute on function public.leave_ranked()        to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  to_regprocedure('public.create_bot_match(int)') is not null as bot_matches_ready,
  to_regprocedure('public.bot_step(uuid)')        is not null as bot_can_play,
  to_regprocedure('public.ranked_tick()')         is not null as queue_ready,
  to_regclass('public.ranked_queue')              is not null as queue_table_created,
  exists (select 1 from information_schema.columns
           where table_name = 'matches' and column_name = 'ranked') as matches_know_ranked;
