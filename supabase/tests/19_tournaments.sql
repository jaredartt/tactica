-- 0028: a whole tournament, from an empty sign-up sheet to a cup.
--
-- Three things in this file are worth more than the rest.
--
-- The first is the BRACKET ARITHMETIC, checked as a property over every size
-- rather than by eyeballing one bracket: seeds in a first-round pair always
-- sum to size+1, and no first-round slot is ever empty however few people
-- entered. The second is that a slot with nobody in it produces a BYE that is
-- recorded as a win, so that everything downstream can be ignorant of byes.
-- The third is that the bracket CANNOT STALL -- a match nobody is playing gets
-- decided, which is the requirement that made cn_tourney_sweep exist.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
delete from public.tournaments;
insert into auth.users (id, email, raw_user_meta_data) values
  ('aa000000-0000-0000-0000-0000000000a1','t1@x.com','{"username":"anna"}'),
  ('aa000000-0000-0000-0000-0000000000a2','t2@x.com','{"username":"bruno"}'),
  ('aa000000-0000-0000-0000-0000000000a3','t3@x.com','{"username":"cira"}'),
  ('aa000000-0000-0000-0000-0000000000a4','t4@x.com','{"username":"dmitri"}'),
  ('aa000000-0000-0000-0000-0000000000a5','t5@x.com','{"username":"elin"}'),
  ('aa000000-0000-0000-0000-0000000000a9','t9@x.com','{"username":"watcher"}');

-- Distinct LP, so "seeded by LP" is a claim that can fail.
update public.profiles set lp = 500 where id = 'aa000000-0000-0000-0000-0000000000a1';
update public.profiles set lp = 400 where id = 'aa000000-0000-0000-0000-0000000000a2';
update public.profiles set lp = 300 where id = 'aa000000-0000-0000-0000-0000000000a3';
update public.profiles set lp = 200 where id = 'aa000000-0000-0000-0000-0000000000a4';
update public.profiles set lp = 100 where id = 'aa000000-0000-0000-0000-0000000000a5';

create or replace function t_join(p_u text) returns void language plpgsql as $$
begin
  perform set_config('app.uid', p_u, false);
  perform public.tournament_join();
end $$;

-- The tournament under test. Pinned once it is running, because the sign-up
-- sheet does not stay the newest row for long: ANY tick creates the next open
-- tournament if there is not one, including a spectator's -- which is correct
-- (sign-ups are always open) and is exactly the kind of thing "the newest row"
-- would have quietly followed.
create or replace function t_tid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('test.tid', true), '')::uuid,
                  (select id from public.tournaments where status = 'open'))
$$;
create or replace function t_pin() returns void language sql as $$
  select set_config('test.tid',
    (select id::text from public.tournaments where status = 'open'), false)::void
$$;
create or replace function t_unpin() returns void language sql as $$
  select set_config('test.tid', '', false)::void
$$;
create or replace function t_locks() returns timestamptz language sql stable as $$
  select locks_at from public.tournaments order by created_at desc limit 1
$$;
-- One slot of the bracket, by where it sits rather than by its id.
create or replace function t_slot(p_r int, p_s int) returns public.tournament_matches
language sql stable as $$
  select * from public.tournament_matches
   where tournament_id = t_tid() and round = p_r and slot = p_s
$$;

-- ---- the bracket arithmetic, as a property ---------------------------------
-- These two lines are the reason cn_tourney_lock has no bye-handling loop in
-- it, so they are asserted over every size the game can produce rather than
-- over the one the rest of this file happens to use.
select t_ok(public.cn_bracket_order(8) = array[1,8,4,5,2,7,3,6],
            'the standard bracket order, so 1 and 2 cannot meet before the final');
do $$
declare s int; o int[]; i int;
begin
  foreach s in array array[2,4,8,16,32,64] loop
    o := public.cn_bracket_order(s);
    if array_length(o,1) <> s then raise exception 'size % came out %', s, array_length(o,1); end if;
    if (select count(distinct x) from unnest(o) x) <> s then
      raise exception 'size % repeats a seed', s; end if;
    i := 1;
    while i < s loop
      if o[i] + o[i+1] <> s + 1 then
        raise exception 'size %: pair (%,%) does not sum to %', s, o[i], o[i+1], s+1; end if;
      -- The property the bye logic leans on: one of any pair is in the better
      -- half, so a slot can never be empty of everybody.
      if least(o[i], o[i+1]) > s / 2 then
        raise exception 'size %: pair (%,%) could be empty', s, o[i], o[i+1]; end if;
      i := i + 2;
    end loop;
  end loop;
end $$;
select t_ok(true, 'AND FOR EVERY BRACKET SIZE: pairs sum to size+1, and no slot can be empty');
select t_ok(public.cn_tourney_size(1) = 2 and public.cn_tourney_size(5) = 8
            and public.cn_tourney_size(8) = 8 and public.cn_tourney_size(9) = 16,
            'a bracket is the smallest power of two that holds everybody');
select t_ok(public.cn_tourney_rounds(2) = 1 and public.cn_tourney_rounds(8) = 3
            and public.cn_tourney_rounds(64) = 6,
            'and the final is always round log2(size)');

-- ---- the countdown ---------------------------------------------------------
select t_join('aa000000-0000-0000-0000-0000000000a1');
select t_ok(t_locks() is null, 'one entrant starts no countdown');
select t_join('aa000000-0000-0000-0000-0000000000a2');
select t_ok(t_locks() is null,
            'and neither do two — two people who want a match already have Ranked');
select t_join('aa000000-0000-0000-0000-0000000000a3');
select t_ok(t_locks() is not null, 'THE THIRD ENTRANT STARTS THE COUNTDOWN');

-- Leaving takes it away again, because the clock is the visible form of
-- "three people are here" and should stop saying so when they are not.
select set_config('app.uid','aa000000-0000-0000-0000-0000000000a3',false);
select public.tournament_leave();
select t_ok(t_locks() is null, 'and dropping back to two cancels it');
select t_join('aa000000-0000-0000-0000-0000000000a3');
select t_ok(t_locks() is not null, 'and a third again restarts it');

select t_join('aa000000-0000-0000-0000-0000000000a4');
select t_join('aa000000-0000-0000-0000-0000000000a5');
select t_ok((select count(*) from public.tournament_entries where tournament_id = t_tid()) = 5,
            'five people are signed up, and sign-ups never closed while they did it');

-- A countdown that does not restart when a fourth arrives. On a busy night a
-- restarting clock never runs out at all.
select t_ok((select count(*) from public.tournaments
              where id = t_tid() and locks_at < now() + public.cn_tourney_wait()
                                 + interval '1 second') = 1,
            'and the clock did not restart when the fourth and fifth joined');

-- ---- an admin may skip the wait; nobody else may ---------------------------
select set_config('app.uid','aa000000-0000-0000-0000-0000000000a5',false);
select t_raises('select public.tournament_start_now()', 'admins only',
                'a player cannot start the tournament early');
-- As the service role, because 0001's trigger reverts an is_admin change made
-- by anybody else -- and the dashboard's SQL editor, which is where Jared
-- grants it, runs as exactly this.
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
update public.profiles set is_admin = true where id = 'aa000000-0000-0000-0000-0000000000a1';
select set_config('request.jwt.claims', '', false);

select t_pin();
select set_config('app.uid','aa000000-0000-0000-0000-0000000000a1',false);
select public.tournament_start_now();

-- ---- the bracket -----------------------------------------------------------
select t_ok((select status from public.tournaments where id = t_tid()) = 'running',
            'and an admin can, which is how this file got here');
select t_ok((select size from public.tournaments where id = t_tid()) = 8
        and (select rounds from public.tournaments where id = t_tid()) = 3,
            'FIVE PEOPLE PLAY A BRACKET OF EIGHT, over three rounds');
select t_ok((select count(*) from public.tournament_matches where tournament_id = t_tid()) = 7,
            'and all seven slots exist at once, so the whole bracket can be drawn');

select t_ok((select seed from public.tournament_entries
              where tournament_id = t_tid()
                and user_id = 'aa000000-0000-0000-0000-0000000000a1') = 1
        and (select seed from public.tournament_entries
              where tournament_id = t_tid()
                and user_id = 'aa000000-0000-0000-0000-0000000000a5') = 5,
            'SEEDED BY LP — the ladder is what the bracket is made of');

-- Byes. Three of them, and they go to seeds 1, 2 and 3 without a line of code
-- anywhere that hands out a bye.
select t_ok((select count(*) from public.tournament_matches
              where tournament_id = t_tid() and round = 1 and bye) = 3,
            'three of the four first-round slots are byes');
select t_ok((select array_agg(e.seed order by e.seed)
               from public.tournament_matches b
               join public.tournament_entries e
                 on e.tournament_id = b.tournament_id and e.user_id = b.winner_id
              where b.tournament_id = t_tid() and b.round = 1 and b.bye)
            = array[1,2,3],
            'AND THE BYES FELL TO THE TOP THREE SEEDS, which nothing in the code asked for');
select t_ok((t_slot(1,1)).a_id is not null and (t_slot(1,1)).b_id is not null
            and (t_slot(1,1)).winner_id is null,
            'and the two lowest seeds have to actually play');

-- A bye is a win that already happened, so it travels the ordinary road: the
-- two byes that feed round 2 slot 1 have already filled it, and a full slot
-- spawns its match without waiting for anything.
select t_ok((t_slot(2,1)).a_id is not null and (t_slot(2,1)).b_id is not null,
            'two byes meeting each other fill their next slot immediately');
select t_ok((t_slot(2,1)).match_id is not null,
            'AND A FULL SLOT BUILDS ITS MATCH AT ONCE — nobody waits for a round to end');
select t_ok((t_slot(2,0)).a_id is not null and (t_slot(2,0)).b_id is null
            and (t_slot(2,0)).match_id is null,
            'while a half-full one waits, and has no match yet');

-- ---- the matches a tournament makes ----------------------------------------
select match_id as m1 from public.tournament_matches
 where tournament_id = t_tid() and round = 1 and slot = 1 \gset
select t_ok((select jsonb_array_length(state->'units') from public.matches where id = :'m1') = 0
        and (select count(*) from public.match_deploy where match_id = :'m1') = 2,
            'A TOURNAMENT MATCH IS BLIND, the same as ranked and rooms are since 0027');
select t_ok((select not ranked from public.matches where id = :'m1'),
            'and it is NOT ranked, because a cup is its own stat');
select t_ok((select tournament_match_id from public.matches where id = :'m1') is not null,
            'and it knows which slot of the bracket it belongs to');
select t_ok((select count(*) from public.match_presence where match_id = :'m1') = 2,
            'with both players already present, so neither is claimed against on arrival');

-- ---- a result advances the bracket -----------------------------------------
-- Through resign_match, on purpose: the point of hanging advancement off a
-- trigger is that the six ways a match can end do not have to know about
-- brackets, and a test that called some cn_tourney_report() would prove
-- nothing about the other five.
select lp from public.profiles where id = 'aa000000-0000-0000-0000-0000000000a4' \gset lp4_
select set_config('app.uid','aa000000-0000-0000-0000-0000000000a5',false);
select public.resign_match(:'m1');

select t_ok((t_slot(1,1)).winner_id = 'aa000000-0000-0000-0000-0000000000a4',
            'A RESIGNATION IS A RESULT, and the bracket heard about it');
select t_ok((t_slot(2,0)).b_id = 'aa000000-0000-0000-0000-0000000000a4',
            'the winner is in the next round');
select t_ok((t_slot(2,0)).match_id is not null,
            'and the slot that was waiting for them has built its match');
select t_ok((select lp from public.profiles where id = 'aa000000-0000-0000-0000-0000000000a4')
            = :lp4_lp
        and (select lp from public.profiles where id = 'aa000000-0000-0000-0000-0000000000a5')
            = 100,
            'AND NOBODY''S LP MOVED — losing a tournament match costs you nothing');
select t_ok((select count(*) from public.match_results) = 0,
            'nor did it land in the ladder''s history');

-- ---- leaving a tournament you are in ---------------------------------------
-- Seed 1 walks away mid-bracket. It has to count as a loss and the other side
-- has to advance, or a bracket is one closed tab away from being stuck.
select set_config('app.uid','aa000000-0000-0000-0000-0000000000a1',false);
select public.tournament_leave();
select t_ok((t_slot(2,0)).winner_id = 'aa000000-0000-0000-0000-0000000000a4',
            'LEAVING COUNTS AS A LOSS and the other side advances');
select t_ok((select status from public.matches
              where id = (t_slot(2,0)).match_id) = 'finished',
            'and the match they walked out of is finished, not left running');
select t_ok((select out_at is not null from public.tournament_entries
              where tournament_id = t_tid()
                and user_id = 'aa000000-0000-0000-0000-0000000000a1'),
            'and they are marked out of the tournament');
select t_ok((t_slot(3,0)).a_id = 'aa000000-0000-0000-0000-0000000000a4'
            and (t_slot(3,0)).match_id is null,
            'so the final has half of itself, and waits rather than building half a match');

-- The other half of the bracket, so there is a final to play. Seed 2 resigns
-- to seed 3, which also puts the LOWER seed through -- the sweep below has to
-- pick a winner by seed, and a bracket where the seeds happen to be in order
-- would not prove which way it picked.
select set_config('app.uid','aa000000-0000-0000-0000-0000000000a2',false);
select public.resign_match((t_slot(2,1)).match_id);
select t_ok((t_slot(3,0)).b_id = 'aa000000-0000-0000-0000-0000000000a3'
            and (t_slot(3,0)).match_id is not null,
            'and the moment it has the rest, the final is a real match');

-- ---- THE BRACKET CANNOT STALL ----------------------------------------------
-- The final is between two people who have both shut their laptops. Nothing
-- in a database moves a clock on its own and force_timeout needs a caller, so
-- before 0028 this match sat there forever. Now any tick from anybody is the
-- referee -- here, from a spectator who is not even in the tournament.
select match_id as f from public.tournament_matches
 where tournament_id = t_tid() and round = 3 and slot = 0 \gset
update public.matches set turn_deadline = now() - interval '5 minutes' where id = :'f';

select set_config('app.uid','aa000000-0000-0000-0000-0000000000a9',false);
select public.tournament_tick();
select t_ok((select status from public.matches where id = :'f') = 'active',
            'a deployment nobody finished is readied up by the referee');

-- Six turns slept through on both sides, which is what the sweep would walk
-- them to one thirty-second turn at a time. Set directly so the test does not
-- take three minutes to say something the sweep decides in one line.
update public.matches
   set state = jsonb_set(state, '{idle}', '{"host":3,"guest":3}'::jsonb),
       turn_deadline = now() - interval '5 minutes'
 where id = :'f';
select set_config('app.uid','aa000000-0000-0000-0000-0000000000a9',false);
select public.tournament_tick();

select t_ok((select status from public.matches where id = :'f') = 'finished',
            'AND A MATCH NOBODY IS PLAYING IS DECIDED, rather than holding up the bracket');
select t_ok((select winner_id from public.tournaments where id = t_tid())
            = 'aa000000-0000-0000-0000-0000000000a3',
            'THE HIGHER SEED goes through — seed 3 over seed 4, and not whoever sat on the left');

-- ---- and the cup -----------------------------------------------------------
select t_ok((select status from public.tournaments where id = t_tid()) = 'finished',
            'the final was the final, so the tournament is over');
select t_ok((select tournaments from public.profiles
              where id = 'aa000000-0000-0000-0000-0000000000a3') = 1,
            'THE CHAMPION HAS A CUP — the column 0026 added for exactly this');
select t_ok((select count(*) from public.profiles where tournaments > 0) = 1,
            'and only the champion; a tally of entries would say something far duller');
select t_ok((select sum(lp) from public.profiles) = 1500
        and (select count(*) from public.match_results) = 0,
            'and the whole thing was LP-NEUTRAL from end to end — not one point moved');

-- ---- sign-ups are already open again ---------------------------------------
select t_unpin();
select set_config('app.uid','aa000000-0000-0000-0000-0000000000a5',false);
select public.tournament_join();
select t_ok((select count(*) from public.tournaments where status = 'open') = 1,
            'a new sheet is taking names, and there is exactly one of them');
select t_ok(t_tid() not in (select id from public.tournaments where status = 'finished'),
            'and it is not one that has already been played');

-- The one-open-at-a-time rule is an index, not a convention, so it holds even
-- against something no function of ours would ever do.
select t_raises($$insert into public.tournaments (status) values ('open')$$,
                'duplicate key', 'and a second open tournament is impossible, not merely unusual');

-- ---- a player in a running bracket cannot enter the next one ---------------
delete from public.tournaments where status = 'open';
select t_join('aa000000-0000-0000-0000-0000000000a1');
select t_join('aa000000-0000-0000-0000-0000000000a2');
select t_join('aa000000-0000-0000-0000-0000000000a3');
select set_config('app.uid','aa000000-0000-0000-0000-0000000000a1',false);
select public.tournament_start_now();
select t_ok((select status from public.tournaments order by created_at desc limit 1) = 'running',
            'a second tournament runs with three people');
select public.tournament_join();
select t_ok((select count(*) from public.tournaments where status = 'open') = 0,
            'AND SOMEBODY STILL IN A BRACKET CANNOT SIGN UP FOR THE NEXT ONE — '
            'which is the only thing a bracket truly cannot survive');
