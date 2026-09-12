-- 0027: ranked deployment is blind again.
--
-- This file is short and it is the file that should have existed since 0012.
--
-- 0008 made deployment secret, and the way it does that is the part that
-- matters: the two armies are not in `matches.state` during the phase at all.
-- They live in match_deploy, one row per side, behind a function that hands
-- you only your own. A policy that merely hid the other side would still put
-- both armies in a row the client downloads, and "you can read it out of the
-- network tab" is not something a competitive mode may say.
--
-- 0012 rewrote ranked_tick for the coin flip and built the match with
-- cn_place(), which writes both armies straight into matches.state, and never
-- called cn_open_deploy(). Ranked has not been blind since.
--
-- It survived because nothing asserted it HERE. 06_bot_ranked.sql checks that
-- the queue pairs people and that the coin is fair; every blind-deployment
-- assertion in the suite is about rooms. So this file asks the question of all
-- three ways a match can begin, in one place, on purpose -- a rule that is
-- only checked on the path somebody happened to think about is a rule with a
-- date on it.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('a9990000-0000-0000-0000-0000000000a9','r1@x.com','{"username":"ranker"}'),
  ('b9990000-0000-0000-0000-0000000000b9','r2@x.com','{"username":"rival"}');

-- The two questions, asked of a match id. Both have to be true at once: units
-- in match_deploy AND nothing in the state. Either one alone can be satisfied
-- by a half-fix that still leaks.
create or replace function t_blind(p_m uuid) returns boolean
language sql stable as $$
  select (select jsonb_array_length(state->'units') from public.matches where id = p_m) = 0
     and (select count(*) from public.match_deploy where match_id = p_m) = 2
$$;
create or replace function t_instate(p_m uuid) returns int
language sql stable as $$
  select jsonb_array_length(state->'units') from public.matches where id = p_m
$$;

-- ---- ranked ----------------------------------------------------------------
select set_config('app.uid','a9990000-0000-0000-0000-0000000000a9',false);
select public.ranked_tick();
select set_config('app.uid','b9990000-0000-0000-0000-0000000000b9',false);
select public.ranked_tick();

select id from public.matches where ranked order by created_at desc limit 1 \gset
select t_ok((select status from public.matches where id = :'id') = 'deploying',
            'the queue paired them and the match is deploying');
select t_ok(t_instate(:'id') = 0,
            'RANKED: NOT ONE UNIT IS IN matches.state — which is the row both clients poll');
select t_ok((select count(*) from public.match_deploy where match_id = :'id') = 2,
            'and there are two half-boards instead, one each');
select t_ok(t_blind(:'id'), 'so a ranked deployment is blind');

-- Each side sees its own five and nothing else. my_deploy is the only door
-- into match_deploy; the table itself has no SELECT policy at all.
select set_config('app.uid','a9990000-0000-0000-0000-0000000000a9',false);
select t_ok(jsonb_array_length(public.my_deploy(:'id')) = public.deck_size(),
            'the host can see their own five');
select set_config('app.uid','b9990000-0000-0000-0000-0000000000b9',false);
select t_ok(jsonb_array_length(public.my_deploy(:'id')) = public.deck_size(),
            'and the guest theirs');
-- Belt and braces on the thing that actually leaked: whatever my_deploy hands
-- back, the shared row has to stay empty of units until both are ready.
select t_ok(t_instate(:'id') = 0,
            'and reading your own half does not put anybody''s on the board');

-- ---- and the other two ways a match can start ------------------------------
select set_config('app.uid','a9990000-0000-0000-0000-0000000000a9',false);
select id, code from public.create_match() as m2 \gset m2_
select set_config('app.uid','b9990000-0000-0000-0000-0000000000b9',false);
select public.join_match(:'m2_code');
select t_ok(t_blind(:'m2_id'), 'a FRIENDS room is blind too');

select set_config('app.uid','a9990000-0000-0000-0000-0000000000a9',false);
select id from public.create_bot_match(2) as m3 \gset m3_
select t_ok((select jsonb_array_length(state->'units') from public.matches where id = :'m3_id') = 0,
            'and PRACTICE keeps its units out of the state as well');
select t_ok((select count(*) from public.match_deploy where match_id = :'m3_id') = 2,
            'with a half-board for the bot as well as for the player');

-- ---- and it becomes visible at exactly the right moment --------------------
-- Blind is a property of the deployment phase, not of the match. The instant
-- both sides are ready the armies belong on the board, and a fix that left
-- them hidden would be a different bug wearing the same shirt.
select set_config('app.uid','a9990000-0000-0000-0000-0000000000a9',false);
select public.set_ready(:'id');
select t_ok(t_instate(:'id') = 0, 'one side ready is still not a board');
select set_config('app.uid','b9990000-0000-0000-0000-0000000000b9',false);
select public.set_ready(:'id');
select t_ok((select status from public.matches where id = :'id') = 'active',
            'both ready and the match starts');
select t_ok(t_instate(:'id') = public.deck_size() * 2,
            'AND NOW EVERY UNIT IS ON THE BOARD, which is the point of the phase ending');
