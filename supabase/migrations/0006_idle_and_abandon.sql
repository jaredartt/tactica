-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  The last statement prints a row of checks. Every column must say true.
-- ===========================================================================
--  0006 — going quiet, and what the other player may do about it
--
--  A player who stops answering is not the same as a player who has lost, and
--  the difference is worth machinery. Reloading the page, a tunnel, a phone
--  that locks -- none of those should cost anyone a rated match.
--
--  So nothing here ever ends a match by itself. Missing three of your own
--  turns in a row marks you AWAY, which is a fact shown to both players and
--  nothing more; the match keeps running and you can walk straight back into
--  it. It only gives your opponent a button, and that button refuses to work
--  while you are still connected, because a browser that is still sending its
--  heartbeat every ten seconds is a browser that is reloading, not one that
--  has gone.
--
--  Two ways it becomes claimable, and both need the three missed turns first:
--    * you are away AND your heartbeat has stopped  -- you actually left
--    * you have missed six                          -- you are there but not
--                                                      playing, and the other
--                                                      player should not be
--                                                      held hostage by an open
--                                                      tab
--
--  "Without doing anything" means exactly that: move or attack with any unit
--  and the count goes back to zero, even if the clock then runs out on you.
--  Pressing End turn also counts -- somebody pressed it.
-- ===========================================================================

alter table public.match_results drop constraint if exists match_results_reason_check;
alter table public.match_results add constraint match_results_reason_check
  check (reason in ('defeat', 'resign', 'abandon'));

-- New rooms carry the counters from the start; older ones grow them on their
-- first turn change, which is why everything below reads them with coalesce.
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
    'idle', jsonb_build_object('host', 0, 'guest', 0),
    'away', null,
    'log', '[]'::jsonb,
    'winner', null);
end $$;

-- ---------------------------------------------------------------------------
-- advance_turn now knows whether the turn it is ending was played or slept
-- through. Two arities rather than one with a DEFAULT: a defaulted argument
-- would make the existing two-argument calls ambiguous against the old
-- signature, and Postgres refuses to choose.
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
  st := jsonb_set(st, '{turn}', to_jsonb(v_next));
  st := jsonb_set(st, '{turnNumber}', to_jsonb(v_turn));
  if p_note is not null then st := state_log(st, p_note); end if;
  st := state_log(st, 'Turn ' || v_turn || ' — '
        || case when v_next = 'host' then m.host_name else m.guest_name end || ' to act.');

  update public.matches
     set state = st, turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

create or replace function public.advance_turn(p_match uuid, p_note text)
returns public.matches language sql security definer set search_path = public as $$
  select public.advance_turn(p_match, p_note, false)
$$;

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
  return advance_turn(p_match, v_loser || ' ran out of time.', true);
end $$;

-- ---------------------------------------------------------------------------
-- claim_win — the only thing the away flag unlocks, and it argues back.
-- ---------------------------------------------------------------------------
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

  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  v_other := case when v_side = 'host' then 'guest' else 'host' end;

  v_n := coalesce((m.state->'idle'->>v_other)::int, 0);
  if v_n < 3 then
    raise exception 'they have not missed three turns yet';
  end if;

  -- Mid-turn return. The counter only resets when their turn ends, so without
  -- this a player who just moved could still be claimed against for the rest
  -- of that turn.
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

  perform finish_match(m.id, v_side, 'abandon');
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

revoke execute on function public.advance_turn(uuid, text)          from public, anon, authenticated;
revoke execute on function public.advance_turn(uuid, text, boolean) from public, anon, authenticated;
revoke execute on function public.cn_fresh_map()                    from public, anon, authenticated;
grant  execute on function public.claim_win(uuid)                   to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  to_regprocedure('public.claim_win(uuid)')                is not null as claim_created,
  to_regprocedure('public.advance_turn(uuid,text,boolean)') is not null as advance_has_timeout_arg,
  (public.cn_fresh_map() ? 'idle')                                     as new_maps_track_idle,
  exists (select 1 from pg_constraint
           where conname = 'match_results_reason_check'
             and pg_get_constraintdef(oid) like '%abandon%')           as abandon_is_a_reason;
