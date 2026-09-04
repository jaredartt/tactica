-- ============================================================================
-- 0002 -- counterattacks
-- ============================================================================
-- Safe to run on a live database and safe to run twice: it only replaces one
-- function. Matches already in progress keep playing; the new rule applies to
-- the next attack in every match, including running ones.
--
-- Paste the whole file into the Supabase SQL editor and hit Run.
-- ============================================================================

create or replace function public.submit_attack(p_match uuid, p_unit text, p_target text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  uid        uuid := auth.uid();
  m          public.matches;
  side       text;
  other      text;
  st         jsonb;
  units      jsonb;
  u          jsonb;
  atk        jsonb;
  tgt        jsonb;
  out_u      jsonb := '[]'::jsonb;
  dist       int;
  dmg        int;
  tgt_hp     int;
  atk_hp     int;
  counter    int := 0;
  killed_tgt boolean := false;
  killed_atk boolean := false;
  foes       int := 0;
  mine       int := 0;
  win        text;
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

  st := m.state;
  units := st->'units';

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

  dmg    := (atk->>'atk')::int;
  tgt_hp := (tgt->>'hp')::int - dmg;
  killed_tgt := tgt_hp <= 0;
  atk_hp := (atk->>'hp')::int;

  -- Counterattack. The defender strikes back only if it survived, the
  -- attacker stands inside its range, AND its own reach is at least as long
  -- as the attacker's. That last clause is the whole rule in one line: you
  -- are only countered by something that can fight at your reach or better.
  -- So an archer shooting from three tiles is safe from a spear, an archer
  -- shooting at another archer trades, and closing to melee with a short
  -- weapon always risks a hit back. The counter is free -- it never consumes
  -- the defender's own action.
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

  -- Structured description of what just happened, so the clients can animate
  -- it. Parsing the log text for this would break the moment the wording
  -- changes; a bumped sequence number is what tells a client this is new.
  st := jsonb_set(st, '{fx}', jsonb_build_object(
    'seq',       coalesce((st->'fx'->>'seq')::int, 0) + 1,
    'atk',       p_unit,
    'tgt',       p_target,
    'dmg',       dmg,
    'killedTgt', killed_tgt,
    'counter',   counter,
    'killedAtk', killed_atk
  ));

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
  elsif mine = 0 then win := other;   -- a counterattack can lose you the match
  end if;

  if win is not null then
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
