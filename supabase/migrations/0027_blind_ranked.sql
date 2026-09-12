-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0026 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0027 - ranked deployment is blind again
--
--  THIS IS A BUG FIX AND IT IS THE ONLY THING IN THIS FILE, because it should
--  go out on its own and immediately.
--
--  0008 made deployment secret. Neither player can see the other's half of the
--  board while they are placing, and the way it does that is the important
--  part: the two armies are NOT in `matches.state` during the phase at all.
--  They live in `match_deploy`, one row per side, behind a function that hands
--  you only your own. A policy that merely hid the other side would still have
--  put both armies in a row the client downloads, and "you can read it out of
--  the network tab" is not a thing a competitive mode may say.
--
--  0012 rewrote ranked_tick to make who-goes-first a coin flip, and in doing so
--  built the match with cn_place() -- which puts both armies straight into
--  matches.state -- and never called cn_open_deploy(). So since 0012, RANKED
--  MATCHES HAVE NOT BEEN BLIND. Both starting layouts have been sitting in the
--  match row that both clients poll, for anybody who opened the network tab.
--  Friends rooms and practice were never affected: join_match and
--  create_bot_match both still open a proper deployment.
--
--  It survived because nothing asserted it. 06_bot_ranked.sql checks that the
--  queue pairs people and that the coin is fair; the blind-deployment
--  assertions in 05 and 08 are all about rooms. A rule with no test is a rule
--  with a date on it.
--
--  The fix is to build the match the way create_bot_match does: a fresh map
--  with no units in it, the row, then cn_open_deploy(). The coin flip, the MMR
--  window, the skip-locked pairing and everything else in the function are
--  spliced across unchanged.
-- ===========================================================================

create or replace function public.ranked_tick()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_name text; v_mmr int; v_joined timestamptz;
  v_them public.ranked_queue; m public.matches; v_st jsonb;
  v_found uuid; v_waiting int; v_host uuid; v_hname text; v_guest uuid; v_gname text;
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

  -- A coin flip, not seniority. Being host is worth two things -- the left
  -- side of the board and the first move -- and neither should be something
  -- you earn by having queued a few seconds earlier. random() is evaluated
  -- once, here on the server, by whichever of the two ticks got through first;
  -- the other player finds the finished match above.
  if random() < 0.5 then
    v_host := v_them.user_id; v_hname := v_them.username; v_guest := v_uid;  v_gname := v_name;
  else
    v_host := v_uid;          v_hname := v_name;          v_guest := v_them.user_id;
    v_gname := v_them.username;
  end if;

  -- THE FIX. A fresh map with NO ARMIES IN IT, and cn_open_deploy() to put
  -- them where only their owner can read them. This used to be two cn_place()
  -- calls writing both armies into matches.state, which is the row both
  -- clients poll. Same shape as create_bot_match and join_match; ranked is no
  -- longer the odd one out.
  v_st := cn_fresh_map();
  v_st := state_log(v_st, 'Ranked match found.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline, ranked)
  values (gen_match_code(), v_host, v_hname, v_guest, v_gname,
          'deploying', v_st, now() + interval '90 seconds', true)
  returning * into m;

  perform cn_open_deploy(m.id, m.state, m.host_id, m.guest_id, null);

  update public.ranked_queue set active = false where user_id in (v_uid, v_them.user_id);
  insert into public.match_presence (match_id, user_id, side) values
    (m.id, m.host_id, 'host'), (m.id, m.guest_id, 'guest')
  on conflict (match_id, user_id) do update set seen_at = now();

  return jsonb_build_object('match', m.id, 'waiting', 0);
end $$;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
--
-- The real proof is in 18_ranked_blind.sql, which pairs two players and looks
-- at the row. What can be asserted from here is the shape of the function --
-- that it no longer writes armies into the state and does open a deployment.
-- ---------------------------------------------------------------------------
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'ranked_tick'
      and p.prosrc like '%cn_open_deploy%')  = 1  as ranked_opens_a_blind_deployment,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'ranked_tick'
      and p.prosrc like '%cn_place%')        = 0  as and_places_nothing_in_the_state,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'ranked_tick'
      and p.prosrc like '%random()%')        = 1  as and_still_flips_the_coin,
  to_regprocedure('public.my_deploy(uuid)') is not null as my_deploy_still_there;
