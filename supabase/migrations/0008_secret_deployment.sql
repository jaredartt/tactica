-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  The last statement prints a row of checks. Every column must say true.
-- ===========================================================================
--  0008 — deployment is meant to be blind
--
--  Every signed-in player can read every match row; that is what makes
--  spectating work, and until now it also meant that while you were arranging
--  your four, your opponent's four were sitting in the same jsonb blob you
--  were looking at. Anyone who opened the network tab could set up against
--  what they had already seen. Hiding it in the client would not have helped
--  in the slightest -- the row is the row.
--
--  So during deployment the positions are not in that row at all. Each side's
--  units live in match_deploy, one row per side, with a policy that shows you
--  only your own. matches.state.units is empty for the whole phase and both
--  armies are written into it in one go at the moment the second player
--  presses Ready -- which is the first instant either of you is entitled to
--  see the other.
--
--  The realtime stream carries the same rows, so it leaks nothing either.
-- ===========================================================================

create table if not exists public.match_deploy (
  match_id uuid not null references public.matches(id) on delete cascade,
  side     text not null check (side in ('host','guest')),
  user_id  uuid references public.profiles(id) on delete cascade,
  units    jsonb not null,
  primary key (match_id, side)
);

alter table public.match_deploy enable row level security;

-- Your own row and nothing else. The bot's row has a null user_id, so it
-- matches nobody and is invisible to everyone including the player it is
-- sitting opposite.
drop policy if exists "see only your own deployment" on public.match_deploy;
create policy "see only your own deployment"
  on public.match_deploy for select to authenticated
  using (user_id = auth.uid());

revoke insert, update, delete on public.match_deploy from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. placing an army, without a board to put it on yet
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

  -- Odd columns first, so four units land spread out rather than in a block.
  for i in 0 .. (v_w - 1) / 2 loop
    if 2 * i + 1 < v_w then v_xs := v_xs || (2 * i + 1); end if;
  end loop;
  for i in 0 .. (v_w - 1) / 2 loop
    if 2 * i < v_w then v_xs := v_xs || (2 * i); end if;
  end loop;

  if p_side = 'host'
    then for i in reverse (v_h - 1) .. (v_h / 2) loop v_ys := v_ys || i; end loop;
    else for i in 0 .. (v_h / 2 - 1)            loop v_ys := v_ys || i; end loop;
  end if;

  for i in 1 .. deck_size() loop
    select * into c from public.cards where slug = p_deck[i];
    if c.id is null then raise exception 'unknown card %', p_deck[i]; end if;

    v_done := false;
    foreach vy in array v_ys loop
      foreach vx in array v_xs loop
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
      'cardId', c.id, 'slug', c.slug, 'name', c.name,
      'hp', c.hp, 'maxHp', c.hp, 'mov', c.mov,
      'rmin', c.rmin, 'rmax', c.rmax, 'crmin', c.crmin, 'crmax', c.crmax,
      'dmin', c.dmin, 'dmax', c.dmax,
      'burns', c.burns, 'heals', c.heals, 'burned', false,
      'accent', c.accent, 'art', c.art_url, 'ability', c.ability,
      'x', vx, 'y', vy, 'moved', false, 'acted', false);
  end loop;
  return v_units;
end $$;

create or replace function public.cn_place(p_state jsonb, p_side text, p_deck text[])
returns jsonb language sql as $$
  select jsonb_set(p_state, '{units}',
                   coalesce(p_state->'units', '[]'::jsonb) || cn_army(p_state, p_side, p_deck))
$$;

-- Both armies placed, and neither one written where the other can see it.
create or replace function public.cn_open_deploy(
  p_match uuid, p_state jsonb, p_host uuid, p_guest uuid, p_bot_deck text[])
returns void language plpgsql as $$
begin
  insert into public.match_deploy (match_id, side, user_id, units) values
    (p_match, 'host',  p_host,
     cn_army(p_state, 'host',  deck_of(p_host))),
    (p_match, 'guest', p_guest,
     cn_army(p_state, 'guest',
             case when p_guest is null then p_bot_deck else deck_of(p_guest) end))
  on conflict (match_id, side) do update set units = excluded.units, user_id = excluded.user_id;
end $$;

create or replace function public.my_deploy(p_match uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare m public.matches; v_side text; v_units jsonb;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null then return null; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then return null; end if;
  select units into v_units from public.match_deploy
   where match_id = p_match and side = v_side;
  return v_units;
end $$;

-- ---------------------------------------------------------------------------
-- 2. the four entry points, now opening a blind deployment
-- ---------------------------------------------------------------------------
create or replace function public.join_match(p_code text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_name text; m public.matches; v_st jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username into v_name from public.profiles where id = v_uid;

  select * into m from public.matches where code = upper(trim(p_code)) for update;
  if m.id is null then raise exception 'no room with that code'; end if;
  if m.host_id = v_uid or m.guest_id = v_uid then return m; end if;
  if m.status <> 'waiting' then raise exception 'that room is already full'; end if;

  v_st := state_log(m.state, v_name || ' entered the arena.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  update public.matches
     set guest_id = v_uid, guest_name = v_name, status = 'deploying',
         state = v_st, turn_deadline = now() + interval '90 seconds', updated_at = now()
   where id = m.id returning * into m;

  perform cn_open_deploy(m.id, m.state, m.host_id, v_uid, null);
  insert into public.match_presence (match_id, user_id, side)
  values (m.id, v_uid, 'guest') on conflict (match_id, user_id) do update set seen_at = now();
  return m;
end $$;

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

  select array_agg(slug) into v_deck
  from (select slug from public.cards where is_active and slug is not null
         order by random() limit deck_size()) s;

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
-- 3. arranging your own half, and the moment both are shown
-- ---------------------------------------------------------------------------
-- It used to hand back the whole match row. Now it hands back your own four
-- and nothing else, which is a different return type, and Postgres will not
-- replace a function's return type in place.
drop function if exists public.deploy_unit(uuid, text, int, int);
create or replace function public.deploy_unit(p_match uuid, p_unit text, p_x int, p_y int)
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
  if not cn_own_half(v_side, p_y, v_h) then raise exception 'that is not your half'; end if;

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
  update public.matches set updated_at = now() where id = p_match;
  return v_out;
end $$;

create or replace function public.cn_set_ready(p_match uuid, p_side text, p_force boolean)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare m public.matches; v_st jsonb; v_host jsonb; v_guest jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  if m.status <> 'deploying' then return m; end if;

  v_st := m.state;
  if p_force then
    v_st := jsonb_set(v_st, '{ready}', jsonb_build_object('host', true, 'guest', true));
    v_st := state_log(v_st, 'Deployment time ran out.');
  else
    v_st := jsonb_set(v_st, array['ready', p_side], 'true'::jsonb);
    v_st := state_log(v_st,
      case when p_side = 'host' then m.host_name else m.guest_name end || ' is ready.');
  end if;

  if not ((v_st->'ready'->>'host')::boolean and (v_st->'ready'->>'guest')::boolean) then
    update public.matches set state = v_st, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  -- Both ready: this is the first moment either of you may see the other, so
  -- this is where the two halves become one board.
  select units into v_host  from public.match_deploy where match_id = p_match and side = 'host';
  select units into v_guest from public.match_deploy where match_id = p_match and side = 'guest';
  if v_host is not null and v_guest is not null then
    v_st := jsonb_set(v_st, '{units}', v_host || v_guest);
  end if;

  v_st := jsonb_set(v_st, '{phase}', '"battle"'::jsonb);
  v_st := jsonb_set(v_st, '{turnNumber}', '1'::jsonb);
  v_st := state_log(v_st, 'Turn 1 — ' || m.host_name || ' to act.');

  update public.matches
     set state = v_st, status = 'active',
         turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

-- ---------------------------------------------------------------------------
-- 4. the other two ways a deployment opens
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

  -- Sides swap, so nobody keeps the first-move advantage two games running.
  v_st := cn_fresh_map();
  v_st := state_log(v_st, 'Rematch on new ground. ' || m.guest_name || ' moves first.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline, ranked)
  values
    (gen_match_code(), m.guest_id, m.guest_name, m.host_id, m.host_name,
     'deploying', v_st, now() + interval '90 seconds', false)
  returning * into nm;

  perform cn_open_deploy(nm.id, nm.state, nm.host_id, nm.guest_id, null);
  insert into public.match_presence (match_id, user_id, side) values
    (nm.id, nm.host_id, 'host'), (nm.id, nm.guest_id, 'guest')
  on conflict (match_id, user_id) do update set seen_at = now();

  update public.matches set next_match_id = nm.id where id = p_match;
  return nm.id;
end $$;

create or replace function public.ranked_tick()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_name text; v_mmr int; v_joined timestamptz;
  v_them public.ranked_queue; m public.matches; v_st jsonb;
  v_found uuid; v_waiting int; v_h uuid; v_hn text; v_g uuid; v_gn text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username into v_name from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;

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
        joined_at = case when public.ranked_queue.active
                          and public.ranked_queue.seen_at > now() - queue_stale()
                         then public.ranked_queue.joined_at else now() end
  returning joined_at into v_joined;

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
  if v_them.joined_at <= v_joined
    then v_h := v_them.user_id; v_hn := v_them.username; v_g := v_uid;         v_gn := v_name;
    else v_h := v_uid;          v_hn := v_name;          v_g := v_them.user_id; v_gn := v_them.username;
  end if;

  v_st := cn_fresh_map();
  v_st := state_log(v_st, 'Ranked match found.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline, ranked)
  values (gen_match_code(), v_h, v_hn, v_g, v_gn,
          'deploying', v_st, now() + interval '90 seconds', true)
  returning * into m;

  perform cn_open_deploy(m.id, m.state, v_h, v_g, null);
  update public.ranked_queue set active = false where user_id in (v_uid, v_them.user_id);
  insert into public.match_presence (match_id, user_id, side) values
    (m.id, v_h, 'host'), (m.id, v_g, 'guest')
  on conflict (match_id, user_id) do update set seen_at = now();

  return jsonb_build_object('match', m.id, 'waiting', 0);
end $$;

revoke execute on function public.cn_open_deploy(uuid, jsonb, uuid, uuid, text[])
  from public, anon, authenticated;
revoke execute on function public.cn_army(jsonb, text, text[]) from public, anon, authenticated;
grant  execute on function public.my_deploy(uuid) to authenticated;
grant  execute on function public.deploy_unit(uuid, text, int, int) to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  to_regclass('public.match_deploy')            is not null as deploy_table_created,
  to_regprocedure('public.my_deploy(uuid)')     is not null as my_deploy_ready,
  exists (select 1 from pg_policies where tablename = 'match_deploy')
                                                            as deployment_is_private,
  jsonb_array_length(public.cn_army(public.cn_fresh_map(), 'host', public.default_deck())) = 4
                                                            as an_army_is_four;
