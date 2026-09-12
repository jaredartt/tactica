-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0028 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0029 - THE WHITE SCREEN, from the server's side
--
--  THIS IS A BUG FIX AND IT IS THE ONLY THING IN THIS FILE.
--
--  Reported from a real game: "every time that I attack, then suddenly
--  everything turns white", on a phone and on a Mac, until a reload. The stack
--  the new crash panel caught said:
--
--      TypeError: Cannot read properties of undefined (reading 'units')
--
--  -- the match screen reading `match.state.units` on a match with no state.
--  `matches.state` is `jsonb not null`, so the database never held such a row.
--  The row that ARRIVED was missing it, and here is why.
--
--  POSTGRES DOES NOT REPLICATE AN UNCHANGED TOASTED COLUMN. A value too big to
--  sit in the row -- over about two kilobytes, which `matches.state` passes the
--  moment there are units on the board -- is stored out of line, and an UPDATE
--  that does not assign it leaves the pointer alone. Logical decoding then has
--  nothing to send for that column and emits a placeholder. Measured, in the
--  WAL, with test_decoding:
--
--      update m set turn_deadline = turn_deadline + '2 seconds' where id = 1;
--      -> table public.m: UPDATE: id[integer]:1
--                         state[jsonb]:unchanged-toast-datum
--                         turn_deadline[timestamptz]:'...'
--
--  Supabase Realtime hands that to the browser as a row with no `state` on it.
--
--  AND 0021 ADDED EXACTLY THAT UPDATE, ON EXACTLY THE ATTACK PATH. The
--  cinematic clock pushes the turn deadline by the length of the fight in a
--  SECOND statement, after cn_attack has already written the board:
--
--      update public.matches set turn_deadline = turn_deadline + ...
--
--  One column, state untouched, state toasted -- so every single attack sent
--  every client a match row with no board on it. Which is the report, exactly:
--  on attacking, every time, on every device, and never in a match so young
--  that the state is still small enough to sit inline.
--
--  `deploy_unit` has the same shape and the same effect: its last statement is
--  `update public.matches set updated_at = now()`, a pure touch whose only
--  purpose is to make realtime fire. It fires all right, and what it sends is
--  a match with no board.
--
--  THE FIX IS TO ASSIGN `state` IN THE SAME STATEMENT. Assigning it from a
--  plpgsql variable -- a value already detoasted in memory -- writes a fresh
--  datum, which is what puts the column back into the WAL. Same measurement,
--  same slot, the other way:
--
--      update m set turn_deadline = ..., state = v where id = 1;
--      -> table public.m: UPDATE: id[integer]:1 state[jsonb]:'[{"id": ...
--
--  It costs rewriting the blob on those two statements, which at this scale is
--  nothing, and it is a far smaller thing to get right than teaching every
--  client to reassemble a row from pieces.
--
--  WHAT IS NOT FIXED HERE, on purpose. The rematch family (request_rematch,
--  decline_rematch) also updates `matches` without touching state, and sends
--  the same half-row. It is left alone because it fires once, at the end of a
--  match, on a screen with no board on it -- and because the client now treats
--  any row that arrives without a state as news rather than as truth and
--  refetches. That guard is the real fix and it covers everything; this file
--  removes the round trip from the two paths that would otherwise pay for it
--  on every attack and every drag of a unit during deployment. 20_toast.sql
--  names the remainder, so the list cannot quietly grow.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. the attack path
--
-- Spliced from 0021 verbatim. The only change is `state = m.state` in the
-- UPDATE -- every check above it, and the cn_cine_ms arithmetic itself, is
-- untouched.
-- ---------------------------------------------------------------------------
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

  m := cn_attack(p_match, v_side, p_unit, p_target);

  -- A finished match has no deadline to push -- cn_attack nulls it on the
  -- winning blow -- and there is no turn left to spend either.
  if m.status = 'active' and m.turn_deadline is not null then
    update public.matches
       set turn_deadline = turn_deadline
             + (cn_cine_ms(m.state->'fx'->'swings') || ' milliseconds')::interval,
           -- THE FIX. Not a no-op and not belt-and-braces: without this
           -- assignment the state column is an unchanged toast pointer, the
           -- WAL carries a placeholder instead of the board, and every client
           -- watching this match receives a row with no state on it. See the
           -- header. `m.state` is the value cn_attack just returned, so this
           -- writes back exactly what is already there.
           state = m.state
     where id = m.id
     returning * into m;
  end if;
  return m;
end $$;

-- ---------------------------------------------------------------------------
-- 2. the deployment path
--
-- Spliced from 0019 verbatim; the only change is the last statement. The touch
-- exists so that realtime tells the other client something happened, which
-- makes it precisely the statement that must not send a half-row.
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
  -- The touch that tells the other client to look again -- and which, without
  -- the state assignment, told it to look at a match with no board.
  update public.matches set state = v_st, updated_at = now() where id = p_match;
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
--
-- The proof that the WAL now carries the board is a logical replication slot
-- and test_decoding, which is not something a migration can run. What can be
-- asserted from here is the shape of the two functions -- that each one's
-- UPDATE on matches assigns state -- which is the thing that was missing.
-- ---------------------------------------------------------------------------
select
  (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'submit_attack')
    like '%state = m.state%'                       as the_attack_path_sends_the_board,
  (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'deploy_unit')
    like '%state = v_st%'                          as and_so_does_deployment,
  (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'submit_attack')
    like '%cn_cine_ms%'                            as the_cinematic_clock_is_untouched,
  to_regprocedure('public.deploy_unit(uuid, text, integer, integer)')
    is not null                                    as deploy_unit_still_there;
