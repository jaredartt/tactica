-- Going quiet, and what the other player may do about it.
\set ON_ERROR_STOP on
\pset pager off

delete from public.matches;
delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('cccccccc-0000-0000-0000-000000000001', 'c@x.com', '{"username":"cara"}'),
  ('dddddddd-0000-0000-0000-000000000002', 'd@x.com', '{"username":"dan"}');

select t_match('cccccccc-0000-0000-0000-000000000001',
               'dddddddd-0000-0000-0000-000000000002') as mid \gset

-- helper: let the clock run out on whoever is to act
create or replace function t_timeout(p_m uuid) returns void language plpgsql as $$
begin
  update public.matches set turn_deadline = now() - interval '5 seconds' where id = p_m;
  perform public.force_timeout(p_m);
end $$;

create or replace function t_idle(p_m uuid, p_side text) returns int
language sql stable as $$
  select coalesce((state->'idle'->>p_side)::int, 0) from public.matches where id = p_m;
$$;
create or replace function t_away(p_m uuid) returns text
language sql stable as $$ select state->>'away' from public.matches where id = p_m $$;

-- rated, so the abandonment assertion below has a result row to look at
update public.matches set ranked = true where id = :'mid';

select set_config('app.uid', 'cccccccc-0000-0000-0000-000000000001', false);
select t_ok(t_idle(:'mid','host') = 0 and t_away(:'mid') is null, 'a fresh match has nobody away');

-- ---- cara sleeps through three of her own turns -------------------------
select t_timeout(:'mid');                       -- host misses 1
select t_ok(t_idle(:'mid','host') = 1, 'a missed turn is counted');
select t_ok(t_away(:'mid') is null, 'one is not enough to be away');
select t_timeout(:'mid');                       -- guest misses 1
select t_ok(t_idle(:'mid','guest') = 1, 'counted per side, not per turn');

select t_timeout(:'mid'); select t_timeout(:'mid');   -- host 2, guest 2
select t_timeout(:'mid');                              -- host 3
select t_ok(t_idle(:'mid','host') = 3, 'three missed turns');
select t_ok(t_away(:'mid') = 'host', 'three in a row marks that side away');
select t_ok((select status from public.matches where id=:'mid') = 'active',
            'and does NOT end the match on its own');

-- ---- but she is still connected, so dan cannot take it ------------------
select set_config('app.uid', 'dddddddd-0000-0000-0000-000000000002', false);
select public.touch_match(:'mid');
select set_config('app.uid', 'cccccccc-0000-0000-0000-000000000001', false);
select public.touch_match(:'mid');              -- cara's browser is still alive
select set_config('app.uid', 'dddddddd-0000-0000-0000-000000000002', false);
select t_raises(format('select public.claim_win(%L)', :'mid'),
                'still connected', 'a reloading player cannot be claimed against');

-- ---- her heartbeat stops -------------------------------------------------
update public.match_presence set seen_at = now() - interval '10 minutes'
 where match_id = :'mid'
   and user_id = 'cccccccc-0000-0000-0000-000000000001';
select public.claim_win(:'mid');
select t_ok((select status from public.matches where id=:'mid') = 'finished', 'now it can be claimed');
select t_ok((select winner from public.matches where id=:'mid') = 'guest', 'and the one still there wins');
select t_ok((select reason from public.match_results order by created_at desc limit 1) = 'abandon',
            'recorded as an abandonment, not a defeat');

-- ---- acting at all resets the count -------------------------------------
select t_match('cccccccc-0000-0000-0000-000000000001',
               'dddddddd-0000-0000-0000-000000000002') as m2 \gset
select set_config('app.uid', 'cccccccc-0000-0000-0000-000000000001', false);
select t_timeout(:'m2'); select t_timeout(:'m2');
select t_timeout(:'m2'); select t_timeout(:'m2');   -- host 2, guest 2
select t_ok(t_idle(:'m2','host') = 2, 'host has missed two');

-- Clear the ground first: the opening formation is laid out around whatever
-- trees were rolled, so which squares are free is not fixed until it is.
select t_trees(:'m2', '[]'::jsonb);
select t_park(:'m2', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_place(:'m2','h1',2,5);                      -- a lane the parked five
select public.submit_move(:'m2','h1',2,4);          -- are not standing in
select t_timeout(:'m2');                            -- then lets the clock go
select t_ok(t_idle(:'m2','host') = 0,
            'moving a single unit resets the count, even if the clock then runs out');

-- pressing End turn is somebody being there too
select t_timeout(:'m2');                            -- guest misses 3 -> away
select t_ok(t_away(:'m2') = 'guest', 'the other side is away now');
select set_config('app.uid', 'cccccccc-0000-0000-0000-000000000001', false);
select public.end_turn(:'m2');
select set_config('app.uid', 'dddddddd-0000-0000-0000-000000000002', false);
select public.end_turn(:'m2');
select t_ok(t_idle(:'m2','guest') = 0 and t_away(:'m2') is null,
            'pressing End turn counts as being there, and clears away');

-- ---- an open tab that never plays can still be claimed after six --------
select set_config('app.uid', 'cccccccc-0000-0000-0000-000000000001', false);
select public.touch_match(:'m2');
select set_config('app.uid', 'dddddddd-0000-0000-0000-000000000002', false);
select public.touch_match(:'m2');
select t_raises(format('select public.claim_win(%L)', :'m2'),
                'not missed three', 'nothing to claim while they are playing');

do $$ begin for i in 1..12 loop perform t_timeout((select id from public.matches
  where status = 'active' order by created_at desc limit 1)); end loop; end $$;
select set_config('app.uid', 'cccccccc-0000-0000-0000-000000000001', false);
select public.touch_match(:'m2');
select set_config('app.uid', 'dddddddd-0000-0000-0000-000000000002', false);
select public.touch_match(:'m2');
select t_ok(t_idle(:'m2','host') >= 6, 'host is six missed turns deep');
select public.claim_win(:'m2');
select t_ok((select status from public.matches where id=:'m2') = 'finished',
            'six missed turns is claimable even with the tab open');

-- ---- spectators are not part of this ------------------------------------
select t_match('cccccccc-0000-0000-0000-000000000001',
               'dddddddd-0000-0000-0000-000000000002') as m3 \gset
insert into auth.users (id, email, raw_user_meta_data) values
  ('eeeeeeee-0000-0000-0000-000000000003', 'e@x.com', '{"username":"eve"}');
select set_config('app.uid', 'eeeeeeee-0000-0000-0000-000000000003', false);
select t_raises(format('select public.claim_win(%L)', :'m3'),
                'spectating', 'a spectator cannot claim anybody''s match');

\echo '--- idle and abandonment: all assertions passed ---'
