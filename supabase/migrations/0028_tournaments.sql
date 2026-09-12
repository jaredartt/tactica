-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0027 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0028 - TOURNAMENTS
--
--  Phase E's server half. A tournament is a single-elimination bracket over
--  whoever signed up, and almost all of the work here is about the two things
--  that make brackets miserable: people who do not turn up, and a bracket that
--  is not a power of two.
--
--  THE LIFECYCLE. Sign-ups are always open -- there is exactly one `open`
--  tournament at any moment, enforced by a partial unique index rather than by
--  everybody remembering. Nothing happens while one or two people are in it,
--  because two people who want a match already have Ranked. THE THIRD ENTRANT
--  STARTS A COUNTDOWN (`locks_at`), and when it runs out the bracket locks
--  around whoever is in at that instant. Somebody who joins with thirty
--  seconds left is in; somebody who joins after is in the NEXT one. Dropping
--  back below three cancels the countdown, because the countdown is not a
--  schedule -- it is the visible form of "three people are here", and it
--  should stop meaning that the moment they are not.
--
--  SEEDING IS BY LP, and it is the only place the ladder reaches into this
--  file. Seeds are laid out in the standard bracket order (1 plays the bottom
--  seed, and 1 and 2 cannot meet before the final), which means BYES FALL TO
--  THE TOP SEEDS for free: the absent seeds are the high-numbered ones, and
--  they are paired with the low-numbered ones by construction. No special
--  case, no "hand out the byes" loop.
--
--  A BYE IS A WIN THAT HAS ALREADY HAPPENED. It is recorded the instant the
--  bracket locks, and it propagates like any other win, so nothing downstream
--  ever has to ask whether a slot was won or walked into.
--
--  LP-NEUTRAL. Tournament matches are `ranked = false`, which is not a new
--  rule: `finish_match` (0004) is the only thing that touches LP and MMR, and
--  every caller already guards it with `if m.ranked`. A cup is its own stat --
--  `profiles.tournaments`, added empty in 0026 and filled here, by the
--  champion only. Losing in the semi-final of a tournament you entered on a
--  whim should not cost you your tier.
--
--  ADVANCEMENT HANGS OFF A TRIGGER ON `matches`, NOT OFF THE WIN PATHS. There
--  are six ways a match can end -- a king dying in cn_attack, resign_match,
--  claim_win, the abandon sweep, force_timeout's chain, and the walkover added
--  below -- and every one of them ends with the same UPDATE setting status to
--  'finished'. Teaching six call sites about brackets would mean the seventh,
--  written next year by somebody not thinking about tournaments, silently
--  stalls a bracket forever. One AFTER UPDATE trigger cannot be forgotten.
--
--  AND THE BRACKET MUST NEVER STALL. That is the hardest requirement in the
--  file and it is why `cn_tourney_sweep` exists. A match between two people
--  who have both closed the tab has, until now, simply sat there: nothing in
--  the database moves a clock on its own, `force_timeout` needs a caller, and
--  both callers have gone. In a friendly room that is nobody's problem. In a
--  bracket it holds up everybody still playing. So the tournament page is the
--  referee: any tick from anybody -- an entrant, a spectator, somebody two
--  rounds away waiting -- pushes every stuck match along, and a match where
--  both sides have slept through three turns each is decided for the higher
--  seed rather than left pending. Arbitrary, and said out loud in the log.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. the tables
-- ---------------------------------------------------------------------------
create table if not exists public.tournaments (
  id          uuid primary key default gen_random_uuid(),
  status      text not null default 'open'
                check (status in ('open', 'running', 'finished')),
  -- null until the third entrant arrives; the countdown the client draws
  locks_at    timestamptz,
  size        int,            -- the power of two the bracket was drawn at
  rounds      int,            -- so round = rounds is the final, wherever it is
  started_at  timestamptz,
  finished_at timestamptz,
  winner_id   uuid references public.profiles(id) on delete set null,
  winner_name text,
  created_at  timestamptz not null default now()
);

-- Exactly one open tournament, said once, here, rather than by every function
-- that might create one. `tournament_join` inserts and lets this refuse.
create unique index if not exists tournaments_one_open
  on public.tournaments((status)) where status = 'open';
create index if not exists tournaments_recent_idx
  on public.tournaments(created_at desc);

create table if not exists public.tournament_entries (
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  username      text not null,
  avatar        text,
  -- LP AS IT WAS WHEN THEY SIGNED UP. Copied, not joined: a seeding that moves
  -- because somebody played a ranked game in another tab during the countdown
  -- is a seeding nobody can check afterwards.
  lp            int not null default 0,
  seed          int,
  joined_at     timestamptz not null default now(),
  seen_at       timestamptz not null default now(),
  out_at        timestamptz,
  primary key (tournament_id, user_id)
);

create table if not exists public.tournament_matches (
  id            uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  round         int not null,
  slot          int not null,
  a_id          uuid references public.profiles(id) on delete set null,
  a_name        text,
  b_id          uuid references public.profiles(id) on delete set null,
  b_name        text,
  match_id      uuid,          -- the real match, once there is one
  winner_id     uuid references public.profiles(id) on delete set null,
  winner_name   text,
  bye           boolean not null default false,
  created_at    timestamptz not null default now(),
  unique (tournament_id, round, slot)
);

-- The link back. NOT a foreign key in the other direction as well: a match is
-- a match whether or not a tournament is watching it, and every rule in the
-- game already works without knowing this column exists.
alter table public.matches
  add column if not exists tournament_match_id uuid
  references public.tournament_matches(id) on delete set null;
create index if not exists matches_tournament_idx
  on public.matches(tournament_match_id) where tournament_match_id is not null;

-- Readable by anyone signed in -- a bracket is a public document and the
-- client renders it straight from these rows. No insert/update/delete policy
-- at all, exactly like `matches`: every write below is a definer function.
alter table public.tournaments        enable row level security;
alter table public.tournament_entries enable row level security;
alter table public.tournament_matches enable row level security;

drop policy if exists "tournaments readable" on public.tournaments;
create policy "tournaments readable" on public.tournaments
  for select to authenticated using (true);
drop policy if exists "entries readable" on public.tournament_entries;
create policy "entries readable" on public.tournament_entries
  for select to authenticated using (true);
drop policy if exists "bracket readable" on public.tournament_matches;
create policy "bracket readable" on public.tournament_matches
  for select to authenticated using (true);

grant select on public.tournaments        to authenticated;
grant select on public.tournament_entries to authenticated;
grant select on public.tournament_matches to authenticated;
revoke insert, update, delete on public.tournaments        from authenticated;
revoke insert, update, delete on public.tournament_entries from authenticated;
revoke insert, update, delete on public.tournament_matches from authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables
                    where pubname='supabase_realtime' and schemaname='public'
                      and tablename='tournaments') then
      alter publication supabase_realtime add table public.tournaments;
    end if;
    if not exists (select 1 from pg_publication_tables
                    where pubname='supabase_realtime' and schemaname='public'
                      and tablename='tournament_entries') then
      alter publication supabase_realtime add table public.tournament_entries;
    end if;
    if not exists (select 1 from pg_publication_tables
                    where pubname='supabase_realtime' and schemaname='public'
                      and tablename='tournament_matches') then
      alter publication supabase_realtime add table public.tournament_matches;
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. the numbers, each in a function so they are tunable in one place
-- ---------------------------------------------------------------------------

-- How long the countdown runs once the third entrant arrives. Long enough for
-- a fourth and fifth to notice, short enough that three people are not sitting
-- in a lobby wondering whether it is broken.
create or replace function public.cn_tourney_wait() returns interval
language sql immutable as $$ select interval '3 minutes' $$;

-- How long past a turn deadline the referee waits before pushing. The two
-- seconds force_timeout already allows are for clock skew; this is for a
-- player whose connection hiccupped, and it is deliberately generous because
-- the cost of being early here is taking a turn off somebody who came back.
create or replace function public.cn_tourney_grace() returns interval
language sql immutable as $$ select interval '20 seconds' $$;

-- The smallest power of two that holds everybody, and never less than two.
create or replace function public.cn_tourney_size(p_n int) returns int
language plpgsql immutable as $$
declare v int := 2;
begin
  while v < greatest(2, coalesce(p_n, 0)) loop v := v * 2; end loop;
  return v;
end $$;

create or replace function public.cn_tourney_rounds(p_size int) returns int
language plpgsql immutable as $$
declare v int := 2; r int := 1;
begin
  while v < p_size loop v := v * 2; r := r + 1; end loop;
  return r;
end $$;

-- THE STANDARD BRACKET ORDER, built the way it is defined rather than typed
-- out: start with [1], and each time the bracket doubles, follow every seed
-- immediately by its new partner, whose number is "one more than the new size
-- minus this one". Size 8 comes out [1,8,4,5,2,7,3,6] -- 1v8, 4v5, 2v7, 3v6.
--
-- Two properties fall out of it and both are load-bearing. The seeds in each
-- first-round pair sum to size+1, so 1 meets the worst seed and 2 meets the
-- second-worst; and any pair therefore contains at least one seed no higher
-- than size/2, WHICH IS WHY A FIRST-ROUND SLOT CAN NEVER BE COMPLETELY EMPTY
-- however few people entered. The bye logic downstream relies on that and
-- would be wrong without it.
create or replace function public.cn_bracket_order(p_size int) returns int[]
language plpgsql immutable as $$
declare v int[] := array[1]; n int := 1; nxt int[]; i int;
begin
  while n < p_size loop
    nxt := '{}'::int[];
    for i in 1..n loop
      nxt := nxt || v[i] || (2 * n + 1 - v[i]);
    end loop;
    v := nxt; n := n * 2;
  end loop;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 3. signing up
-- ---------------------------------------------------------------------------
create or replace function public.cn_tourney_open() returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  select id into v_id from public.tournaments where status = 'open';
  if v_id is not null then return v_id; end if;
  -- The partial unique index is the referee if two people sign up at once.
  insert into public.tournaments (status) values ('open')
    on conflict do nothing returning id into v_id;
  if v_id is null then
    select id into v_id from public.tournaments where status = 'open';
  end if;
  return v_id;
end $$;

create or replace function public.tournament_join()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_name text; v_avatar text; v_lp int;
  v_t uuid; v_n int; v_locks timestamptz;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username, avatar, lp into v_name, v_avatar, v_lp
    from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;

  -- Already in one that is being played? Then that is your tournament, and
  -- joining the next one while you still owe somebody a match is exactly the
  -- thing a bracket cannot survive.
  select t.id into v_t from public.tournaments t
    join public.tournament_entries e on e.tournament_id = t.id
   where e.user_id = v_uid and t.status = 'running' and e.out_at is null
   limit 1;
  if v_t is not null then return public.tournament_state(v_t); end if;

  v_t := cn_tourney_open();

  insert into public.tournament_entries
    (tournament_id, user_id, username, avatar, lp)
  values (v_t, v_uid, v_name, v_avatar, coalesce(v_lp, 0))
  on conflict (tournament_id, user_id) do update
    set seen_at = now(), username = excluded.username,
        avatar = excluded.avatar, lp = excluded.lp, out_at = null;

  -- THE THIRD ENTRANT STARTS THE CLOCK, and only the third: a countdown that
  -- restarted every time somebody joined would never run out on a busy night.
  select count(*) into v_n from public.tournament_entries
   where tournament_id = v_t and out_at is null;
  select locks_at into v_locks from public.tournaments where id = v_t;
  if v_n >= 3 and v_locks is null then
    update public.tournaments set locks_at = now() + cn_tourney_wait()
     where id = v_t and status = 'open';
  end if;

  return public.tournament_state(v_t);
end $$;

create or replace function public.tournament_leave()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_t uuid; v_n int;
  tm public.tournament_matches; m public.matches;
begin
  if v_uid is null then raise exception 'not signed in'; end if;

  -- Running first: leaving a bracket you are already in is a forfeit, and it
  -- has to be the one that is found, not the sign-up sheet for the next one.
  select t.id into v_t from public.tournaments t
    join public.tournament_entries e on e.tournament_id = t.id
   where e.user_id = v_uid and t.status = 'running' and e.out_at is null limit 1;

  if v_t is not null then
    update public.tournament_entries set out_at = now()
     where tournament_id = v_t and user_id = v_uid;

    -- Whatever they were in the middle of is now their opponent's. A pending
    -- slot needs nothing: cn_tourney_spawn checks out_at before it builds a
    -- match, so the walkover happens when the other side is known.
    for tm in select * from public.tournament_matches
               where tournament_id = v_t and winner_id is null
                 and (a_id = v_uid or b_id = v_uid) loop
      if tm.match_id is not null then
        -- The side that loses is the side THIS PLAYER is sitting on, and which
        -- one that is has nothing to do with a and b: cn_tourney_spawn tosses
        -- a coin for host. Ask the match, not the bracket.
        select * into m from public.matches where id = tm.match_id;
        perform cn_tourney_walkover(tm.match_id,
                 case when m.host_id = v_uid then 'guest' else 'host' end,
                 ' left the tournament.');
      else
        perform cn_tourney_spawn(tm.id);
      end if;
    end loop;
    return public.tournament_state(v_t);
  end if;

  select t.id into v_t from public.tournaments t
    join public.tournament_entries e on e.tournament_id = t.id
   where e.user_id = v_uid and t.status = 'open' limit 1;
  if v_t is null then return public.tournament_state(cn_tourney_open()); end if;

  delete from public.tournament_entries
   where tournament_id = v_t and user_id = v_uid;

  -- Back under three and the countdown stops, because the countdown was only
  -- ever the visible form of "three people are here".
  select count(*) into v_n from public.tournament_entries
   where tournament_id = v_t and out_at is null;
  if v_n < 3 then
    update public.tournaments set locks_at = null where id = v_t and status = 'open';
  end if;
  return public.tournament_state(v_t);
end $$;

-- ---------------------------------------------------------------------------
-- 4. locking the bracket
-- ---------------------------------------------------------------------------
create or replace function public.cn_tourney_lock(p_t uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  t public.tournaments; v_n int; v_size int; v_rounds int; v_ord int[];
  r int; s int; v_a public.tournament_entries; v_b public.tournament_entries;
  tm public.tournament_matches;
begin
  select * into t from public.tournaments where id = p_t for update;
  if t.id is null or t.status <> 'open' then return; end if;

  select count(*) into v_n from public.tournament_entries
   where tournament_id = p_t and out_at is null;
  -- Everyone left during the countdown. Not an error and not a tournament:
  -- clear the clock and go on taking sign-ups.
  if v_n < 2 then
    update public.tournaments set locks_at = null where id = p_t;
    return;
  end if;

  -- SEEDS. LP first, and the earlier sign-up ahead on a tie, which is the
  -- only tiebreak that cannot be gamed by refreshing.
  with sd as (
    select user_id, row_number() over (order by lp desc, joined_at, user_id) rn
      from public.tournament_entries
     where tournament_id = p_t and out_at is null)
  update public.tournament_entries e set seed = sd.rn
    from sd where sd.user_id = e.user_id and e.tournament_id = p_t;

  v_size   := cn_tourney_size(v_n);
  v_rounds := cn_tourney_rounds(v_size);
  v_ord    := cn_bracket_order(v_size);

  -- EVERY SLOT OF EVERY ROUND UP FRONT, empty ones included, so the client can
  -- draw the whole bracket the instant it locks instead of watching it grow.
  for r in 1..v_rounds loop
    for s in 0..(v_size / (2 ^ r)::int) - 1 loop
      insert into public.tournament_matches (tournament_id, round, slot)
      values (p_t, r, s) on conflict (tournament_id, round, slot) do nothing;
    end loop;
  end loop;

  for s in 0..(v_size / 2) - 1 loop
    select * into v_a from public.tournament_entries
     where tournament_id = p_t and seed = v_ord[2 * s + 1];
    select * into v_b from public.tournament_entries
     where tournament_id = p_t and seed = v_ord[2 * s + 2];
    update public.tournament_matches
       set a_id = v_a.user_id, a_name = v_a.username,
           b_id = v_b.user_id, b_name = v_b.username
     where tournament_id = p_t and round = 1 and slot = s;
  end loop;

  update public.tournaments
     set status = 'running', size = v_size, rounds = v_rounds,
         started_at = now(), locks_at = null
   where id = p_t;

  -- Byes are wins that have already happened, so they are recorded now and
  -- travel the ordinary road. Only then are the real first-round matches
  -- built, so that a bye's parent slot already knows half of itself.
  for tm in select * from public.tournament_matches
             where tournament_id = p_t and round = 1 order by slot loop
    if tm.a_id is null and tm.b_id is null then
      -- Cannot happen: see cn_bracket_order. Recorded rather than assumed.
      raise exception 'bracket slot % of tournament % has nobody in it', tm.slot, p_t;
    elsif tm.b_id is null then
      update public.tournament_matches set bye = true where id = tm.id;
      perform cn_tourney_win(tm.id, tm.a_id, tm.a_name);
    elsif tm.a_id is null then
      update public.tournament_matches set bye = true where id = tm.id;
      perform cn_tourney_win(tm.id, tm.b_id, tm.b_name);
    end if;
  end loop;

  for tm in select * from public.tournament_matches
             where tournament_id = p_t and round = 1 and winner_id is null
             order by slot loop
    perform cn_tourney_spawn(tm.id);
  end loop;
end $$;

-- An admin may skip the countdown. Testing needs it and a Friday night with
-- three people who are all obviously present needs it too. It is the only
-- thing in this file that asks who you are.
create or replace function public.tournament_start_now()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t uuid;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and is_admin) then
    raise exception 'admins only';
  end if;
  select id into v_t from public.tournaments where status = 'open';
  if v_t is null then raise exception 'nothing to start'; end if;
  perform cn_tourney_lock(v_t);
  return public.tournament_state(v_t);
end $$;

-- ---------------------------------------------------------------------------
-- 5. building one match of the bracket
--
-- The same four steps as create_bot_match and, since 0027, ranked_tick: a
-- fresh map with NO ARMIES IN IT, the row, cn_open_deploy so that each side
-- can read only its own half, and presence. Spliced rather than invented --
-- a fifth way to start a match would be a fifth way to get blind deployment
-- wrong.
-- ---------------------------------------------------------------------------
create or replace function public.cn_tourney_spawn(p_tm uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  tm public.tournament_matches; v_st jsonb; m public.matches;
  v_a_out boolean; v_b_out boolean;
  v_host uuid; v_hname text; v_guest uuid; v_gname text;
begin
  select * into tm from public.tournament_matches where id = p_tm for update;
  if tm.id is null or tm.winner_id is not null or tm.match_id is not null then return; end if;
  if tm.a_id is null or tm.b_id is null then return; end if;   -- still waiting

  select out_at is not null into v_a_out from public.tournament_entries
   where tournament_id = tm.tournament_id and user_id = tm.a_id;
  select out_at is not null into v_b_out from public.tournament_entries
   where tournament_id = tm.tournament_id and user_id = tm.b_id;

  -- Somebody has already walked away. No point building a board for it.
  -- Both gone advances A, which is arbitrary and is the honest answer to a
  -- question with no better one -- the bracket has to keep moving.
  if coalesce(v_a_out, false) then
    perform cn_tourney_win(p_tm, tm.b_id, tm.b_name); return;
  elsif coalesce(v_b_out, false) then
    perform cn_tourney_win(p_tm, tm.a_id, tm.a_name); return;
  end if;

  -- A COIN, not the seed. 0012 made the first move a coin flip in ranked on
  -- the grounds that being host is worth two things -- the left of the board
  -- and the first turn -- and neither should fall out of how you got here.
  -- That argument is stronger in a bracket, not weaker: the seed has already
  -- been paid out, in the shape of a bye.
  if random() < 0.5 then
    v_host := tm.a_id; v_hname := tm.a_name; v_guest := tm.b_id; v_gname := tm.b_name;
  else
    v_host := tm.b_id; v_hname := tm.b_name; v_guest := tm.a_id; v_gname := tm.a_name;
  end if;

  v_st := cn_fresh_map();
  v_st := state_log(v_st, 'Tournament — round ' || tm.round || '.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state,
     turn_deadline, ranked, tournament_match_id)
  values (gen_match_code(), v_host, v_hname, v_guest, v_gname,
          'deploying', v_st, now() + interval '90 seconds', false, p_tm)
  returning * into m;

  perform cn_open_deploy(m.id, m.state, m.host_id, m.guest_id, null);
  insert into public.match_presence (match_id, user_id, side) values
    (m.id, m.host_id, 'host'), (m.id, m.guest_id, 'guest')
  on conflict (match_id, user_id) do update set seen_at = now();

  update public.tournament_matches set match_id = m.id where id = p_tm;
end $$;

-- ---------------------------------------------------------------------------
-- 6. a result, and everything that follows from it
-- ---------------------------------------------------------------------------
create or replace function public.cn_tourney_win(p_tm uuid, p_win uuid, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare
  tm public.tournament_matches; t public.tournaments;
  v_parent public.tournament_matches; v_slot int;
begin
  select * into tm from public.tournament_matches where id = p_tm for update;
  if tm.id is null or tm.winner_id is not null then return; end if;  -- never twice
  if p_win is null then return; end if;

  update public.tournament_matches
     set winner_id = p_win, winner_name = p_name where id = p_tm;

  select * into t from public.tournaments where id = tm.tournament_id;

  -- The final. `round = rounds` rather than a flag, so a bracket of two and a
  -- bracket of thirty-two end in exactly the same line of code.
  if tm.round >= t.rounds then
    update public.tournaments
       set status = 'finished', finished_at = now(),
           winner_id = p_win, winner_name = p_name
     where id = t.id and status = 'running';
    -- THE CUP. The champion only: 0026 added this column for the thing people
    -- put next to their name, and a column that counted entries would say
    -- something much less interesting.
    update public.profiles set tournaments = tournaments + 1 where id = p_win;
    return;
  end if;

  -- Upwards. Slot s of round r feeds slot s/2 of round r+1, on the left if s
  -- is even -- which is the same arithmetic the client draws the lines with.
  v_slot := tm.slot / 2;
  if tm.slot % 2 = 0 then
    update public.tournament_matches set a_id = p_win, a_name = p_name
     where tournament_id = t.id and round = tm.round + 1 and slot = v_slot;
  else
    update public.tournament_matches set b_id = p_win, b_name = p_name
     where tournament_id = t.id and round = tm.round + 1 and slot = v_slot;
  end if;

  select * into v_parent from public.tournament_matches
   where tournament_id = t.id and round = tm.round + 1 and slot = v_slot;
  if v_parent.a_id is not null and v_parent.b_id is not null then
    perform cn_tourney_spawn(v_parent.id);
  end if;
end $$;

-- THE HOOK. Every way a match can end -- a king falling, a resignation, a
-- claim, the abandon sweep, a timeout chain, the walkover below -- ends with
-- the same UPDATE, and this catches all six without any of them knowing.
create or replace function public.cn_match_finished()
returns trigger language plpgsql security definer set search_path = public as $$
declare tm public.tournament_matches; v_id uuid; v_name text;
begin
  select * into tm from public.tournament_matches where id = new.tournament_match_id;
  if tm.id is null or tm.winner_id is not null then return null; end if;
  if new.winner = 'host' then v_id := new.host_id; v_name := new.host_name;
  else                        v_id := new.guest_id; v_name := new.guest_name; end if;
  perform cn_tourney_win(tm.id, v_id, v_name);
  return null;
end $$;

drop trigger if exists matches_advance_the_bracket on public.matches;
create trigger matches_advance_the_bracket
  after update on public.matches
  for each row
  when (new.tournament_match_id is not null
        and new.status = 'finished' and old.status is distinct from 'finished'
        and new.winner is not null)
  execute function public.cn_match_finished();

-- ---------------------------------------------------------------------------
-- 7. the referee
--
-- A walkover is written exactly the way resign_match writes one, because a
-- match that ended is a match that ended and the client must not be able to
-- tell the difference by looking at the shape of the row.
-- ---------------------------------------------------------------------------
create or replace function public.cn_tourney_walkover(p_match uuid, p_win text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare m public.matches; v_st jsonb; v_loser text;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null or m.status = 'finished' then return; end if;
  v_loser := case when p_win = 'host' then m.guest_name else m.host_name end;
  v_st := state_log(m.state, v_loser || p_note);
  v_st := state_log(v_st,
          case when p_win = 'host' then m.host_name else m.guest_name end || ' advances.');
  v_st := jsonb_set(v_st, '{winner}', to_jsonb(p_win));
  update public.matches
     set state = v_st, status = 'finished', winner = p_win,
         turn_deadline = null, updated_at = now()
   where id = m.id;
end $$;

create or replace function public.cn_tourney_sweep(p_t uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  tm public.tournament_matches; m public.matches;
  v_hi int; v_gi int; v_a_seed int; v_b_seed int; v_win text;
begin
  for tm in select * from public.tournament_matches
             where tournament_id = p_t and winner_id is null and match_id is not null loop
    select * into m from public.matches where id = tm.match_id;
    continue when m.id is null;

    -- A finished match whose trigger never ran -- a row written before 0028,
    -- or a restore. Cheap to check and it is the difference between a stuck
    -- bracket and a late one.
    if m.status = 'finished' then
      if m.winner is not null then
        perform cn_tourney_win(tm.id,
          case when m.winner = 'host' then m.host_id else m.guest_id end,
          case when m.winner = 'host' then m.host_name else m.guest_name end);
      end if;
      continue;
    end if;

    continue when m.turn_deadline is null;
    continue when now() <= m.turn_deadline + cn_tourney_grace();

    v_hi := coalesce((m.state->'idle'->>'host')::int, 0);
    v_gi := coalesce((m.state->'idle'->>'guest')::int, 0);

    if m.status = 'active' and v_hi >= 3 and v_gi >= 3 then
      -- NOBODY IS HERE. This is the case that would otherwise hold up every
      -- player still in the tournament, waiting for two people who have shut
      -- their laptops. The higher seed goes through; it is arbitrary, it is
      -- the least arbitrary thing available, and the log says so.
      select seed into v_a_seed from public.tournament_entries
       where tournament_id = p_t and user_id = tm.a_id;
      select seed into v_b_seed from public.tournament_entries
       where tournament_id = p_t and user_id = tm.b_id;
      v_win := case when coalesce(v_a_seed, 999) <= coalesce(v_b_seed, 999)
                    then tm.a_id else tm.b_id end::text;
      perform cn_tourney_walkover(m.id,
        case when v_win = m.host_id::text then 'host' else 'guest' end,
        ' and their opponent both went away; the bracket moves on.');
    elsif m.status = 'active' and v_hi >= 6 then
      perform cn_tourney_walkover(m.id, 'guest', ' never came back.');
    elsif m.status = 'active' and v_gi >= 6 then
      perform cn_tourney_walkover(m.id, 'host', ' never came back.');
    else
      -- The ordinary push: ready them up if deployment has expired, or end
      -- the turn of whoever is asleep. Idempotent, and it is the same
      -- function the match screen itself calls.
      perform force_timeout(m.id);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 8. the tick, and the view the client draws from
-- ---------------------------------------------------------------------------
create or replace function public.tournament_state(p_t uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t public.tournaments; v_uid uuid := auth.uid(); v jsonb;
begin
  select * into t from public.tournaments where id = p_t;
  if t.id is null then return null; end if;

  v := jsonb_build_object(
    'id', t.id, 'status', t.status,
    'locksAt', t.locks_at, 'startedAt', t.started_at, 'finishedAt', t.finished_at,
    'size', t.size, 'rounds', t.rounds,
    'winnerId', t.winner_id, 'winnerName', t.winner_name,
    'now', now(),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.user_id, 'name', e.username, 'avatar', e.avatar,
               'lp', e.lp, 'seed', e.seed, 'out', e.out_at is not null)
             order by coalesce(e.seed, 9999), e.joined_at)
        from public.tournament_entries e where e.tournament_id = t.id), '[]'::jsonb),
    'bracket', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', b.id, 'round', b.round, 'slot', b.slot,
               'aId', b.a_id, 'aName', b.a_name,
               'bId', b.b_id, 'bName', b.b_name,
               'match', b.match_id, 'winnerId', b.winner_id,
               'winnerName', b.winner_name, 'bye', b.bye)
             order by b.round, b.slot)
        from public.tournament_matches b where b.tournament_id = t.id), '[]'::jsonb));

  -- "Where am I" answered by the server, because the client working it out of
  -- the bracket means the client working it out of the bracket twice.
  return jsonb_set(v, '{me}', jsonb_build_object(
    'in', exists (select 1 from public.tournament_entries
                   where tournament_id = t.id and user_id = v_uid and out_at is null),
    'out', exists (select 1 from public.tournament_entries
                    where tournament_id = t.id and user_id = v_uid and out_at is not null),
    'seed', (select seed from public.tournament_entries
              where tournament_id = t.id and user_id = v_uid),
    'match', (select b.match_id from public.tournament_matches b
               where b.tournament_id = t.id and b.winner_id is null
                 and b.match_id is not null
                 and (b.a_id = v_uid or b.b_id = v_uid) limit 1)));
end $$;

-- Anybody's tick drives everybody's tournament. A spectator on the bracket
-- page is as good a referee as an entrant, and better than nobody -- which is
-- precisely the case a bracket has to survive.
create or replace function public.tournament_tick()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_t uuid; r record;
begin
  if v_uid is null then raise exception 'not signed in'; end if;

  update public.tournament_entries set seen_at = now()
   where user_id = v_uid and tournament_id in
     (select id from public.tournaments where status in ('open', 'running'));

  for r in select id from public.tournaments
            where status = 'open' and locks_at is not null and locks_at <= now() loop
    perform cn_tourney_lock(r.id);
  end loop;
  for r in select id from public.tournaments where status = 'running' loop
    perform cn_tourney_sweep(r.id);
  end loop;

  -- Mine, if I am in one; otherwise whatever is taking sign-ups.
  select t.id into v_t from public.tournaments t
    join public.tournament_entries e on e.tournament_id = t.id
   where e.user_id = v_uid and t.status = 'running' limit 1;
  if v_t is null then v_t := cn_tourney_open(); end if;
  return public.tournament_state(v_t);
end $$;

-- ---------------------------------------------------------------------------
-- 9. who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.cn_tourney_wait()              from public, anon, authenticated;
revoke execute on function public.cn_tourney_grace()             from public, anon, authenticated;
revoke execute on function public.cn_tourney_size(int)           from public, anon, authenticated;
revoke execute on function public.cn_tourney_rounds(int)         from public, anon, authenticated;
revoke execute on function public.cn_bracket_order(int)          from public, anon, authenticated;
revoke execute on function public.cn_tourney_open()              from public, anon, authenticated;
revoke execute on function public.cn_tourney_lock(uuid)          from public, anon, authenticated;
revoke execute on function public.cn_tourney_spawn(uuid)         from public, anon, authenticated;
revoke execute on function public.cn_tourney_win(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.cn_tourney_walkover(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.cn_tourney_sweep(uuid)         from public, anon, authenticated;
revoke execute on function public.cn_match_finished()            from public, anon, authenticated;

grant execute on function public.tournament_join()       to authenticated;
grant execute on function public.tournament_leave()      to authenticated;
grant execute on function public.tournament_tick()       to authenticated;
grant execute on function public.tournament_state(uuid)  to authenticated;
grant execute on function public.tournament_start_now()  to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
--
-- The real proof is 19_tournaments.sql, which plays a five-person bracket
-- through to a champion. What can be asserted from here is that the shapes
-- exist and that the bracket arithmetic -- the one piece of this file that is
-- pure maths and therefore checkable in one line -- is right.
-- ---------------------------------------------------------------------------
select
  to_regclass('public.tournaments')        is not null as tournaments_table,
  to_regclass('public.tournament_entries') is not null as entries_table,
  to_regclass('public.tournament_matches') is not null as bracket_table,
  public.cn_bracket_order(8) = array[1,8,4,5,2,7,3,6] as the_bracket_is_seeded_properly,
  public.cn_tourney_size(5) = 8 and public.cn_tourney_rounds(8) = 3
                                                       as five_people_play_three_rounds,
  (select count(*) from pg_trigger
    where tgname = 'matches_advance_the_bracket') = 1  as every_ending_advances_the_bracket,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='matches'
      and column_name='tournament_match_id') = 1       as matches_know_their_slot;
