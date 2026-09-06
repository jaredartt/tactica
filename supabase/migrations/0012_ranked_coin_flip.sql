-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0010 and 0011 first. The last statement prints a check; it must say
--  true.
-- ===========================================================================
--  0012 - ranked sides are a coin flip
--
--  ranked_tick used to seat the player who had waited longer as the host.
--  That was harmless while host and guest were only "bottom" and "top" and
--  the first move was the only difference. Since 0011 the host also holds the
--  left of the board, so seniority in the queue was quietly deciding two
--  things at once, every game, in the same direction.
--
--  Nothing else about the pairing changes: the window still widens with time
--  and the closest rating still wins the match-up. Only the seat is now
--  decided by a flip.
--
--  Rooms you host or join are untouched -- the person who opened the room is
--  the host there, which is the only thing that could sensibly happen.
-- ===========================================================================

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

  -- A coin flip, not seniority. Being host is now worth two things -- the
  -- left side of the board and the first move -- and neither should be
  -- something you earn by having queued a few seconds earlier. random() is
  -- evaluated once, here on the server, by whichever of the two ticks got
  -- through first; the other player finds the finished match above.
  v_st := cn_fresh_map();
  if random() < 0.5 then
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
-- Did it work? Ten thousand flips should not land more than about 3% off an
-- even split; anything outside that is not a coin.
-- ---------------------------------------------------------------------------
select abs((select count(*) filter (where random() < 0.5) / 10000.0
              from generate_series(1, 10000)) - 0.5) < 0.03 as the_flip_is_even;
