-- A face and a name: what you are allowed to be called, and what you are
-- allowed to wear.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('aa000000-0000-0000-0000-00000000000a', 'a@x.com', '{"username":"ann"}'),
  ('bb000000-0000-0000-0000-00000000000b', 'b@x.com', '{"username":"ben"}');

select set_config('app.uid', 'aa000000-0000-0000-0000-00000000000a', false);

-- ---- the face ------------------------------------------------------------
select t_ok(public.set_avatar('sinie') = 'sinie', 'you can wear a card from the roster');
select t_ok((select avatar from public.profiles where id = auth.uid()) = 'sinie', 'and it sticks');
select t_raises('select public.set_avatar(''gandalf'')',
                'no such card', 'but not one that does not exist');
select t_ok(public.set_avatar(null) is null, 'and you can take it off again');

-- The update policy still lets a client write its own row, so the rule cannot
-- live only in the function.
select public.set_avatar('mako');
update public.profiles set avatar = 'gandalf' where id = auth.uid();
select t_ok((select avatar from public.profiles where id = auth.uid()) is null,
            'a bogus icon written straight to the row is dropped by the trigger');

-- A card that leaves the roster does not leave a broken icon behind, because
-- the next write is checked against the roster as it is then.
select public.set_avatar('mako');
update public.cards set is_active = false where slug = 'mako';
update public.profiles set avatar = 'mako' where id = auth.uid();
select t_ok((select avatar from public.profiles where id = auth.uid()) is null,
            'nor one that has since been retired');
update public.cards set is_active = true where slug = 'mako';

-- ---- the name ------------------------------------------------------------
select t_ok(public.set_username('Ann Again') = 'Ann Again', 'you can rename yourself');
select t_raises('select public.set_username(''a'')', '2 and 20', 'a name has a floor');
select t_raises('select public.set_username(''a<b>'')',
                'letters, numbers', 'and a shape');
select t_raises('select public.set_username(''ben'')', 'taken', 'and has to be free');
select t_ok((select username from public.profiles where id = auth.uid()) = 'Ann Again',
            'the name that stuck is the one that was allowed');
select t_ok(public.set_username('  Ann Again  ') = 'Ann Again',
            'and the spaces around it are not part of it');

-- ---- the ladder carries the face ----------------------------------------
select public.set_avatar('sinie');
update public.profiles set games = 1, wins = 1 where id = auth.uid();
select t_ok((select avatar from public.leaderboard where id = auth.uid()) = 'sinie',
            'the ladder shows it too');

\echo '--- profiles: all assertions passed ---'
