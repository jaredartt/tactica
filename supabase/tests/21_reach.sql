-- 0030: one number, and it starts at 1.
--
--   "range 2 means being able to attack 1 and 2 tiles far away, and range 3
--    means 1, 2, and 3 tiles far away"     -- Jared
--   "range and reach IS THE SAME thing"    -- Jared
--
-- Two cards had a hole in the middle of their range: Dereo struck at exactly 2
-- and Fey at 2 or 3, so neither could answer anything standing next to it. The
-- fix is not eleven UPDATEs, it is that `cn_check_card` now DERIVES all four
-- reach columns from `range` -- so the assertions worth writing are about a
-- card nobody has written yet as much as about the eleven that exist.
\set ON_ERROR_STOP on
\pset pager off

-- ---- every card that is here now --------------------------------------------
select t_ok((select count(*) from public.cards where rmin <> 1) = 0,
            'NOT ONE CARD HAS A HOLE IN ITS RANGE — every reach starts at 1');
select t_ok((select count(*) from public.cards where crmin <> 1 or crmax <> rmax) = 0,
            'and every card answers anything it could have struck, which is what "the same thing" means');
select t_ok((select count(*) from public.cards where range <> rmax) = 0,
            'and the number a player reads is the number the engine uses');

-- The two this was reported about, by name, because "no card has X" passes
-- happily on an empty table and these are the two that were wrong.
select t_ok((select range from public.cards where slug = 'dereo') = 2
        and (select rmin from public.cards where slug = 'dereo') = 1,
            'DEREO still reaches two, and can now be got at from next door');
select t_ok((select range from public.cards where slug = 'fey') = 3
        and (select rmin from public.cards where slug = 'fey') = 1
        and (select crmax from public.cards where slug = 'fey') = 3,
            'FEY still reaches three, at one and two as well, and answers across all three');

-- ---- and every card nobody has written yet ----------------------------------
-- The rule lives in the trigger, so this is the assertion that keeps it true
-- next month: a hand-written row with a minimum range comes back without one.
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
insert into public.cards
  (slug, name, role, hp, mov, rmin, rmax, crmin, crmax, dmin, dmax, range,
   ability, accent, art_url, sort, is_active)
values ('rangetest', 'Range Test', 'Mage', 70, 2, 3, 3, 3, 3, 10, 20, 3,
        'A card written the old way.', '#123456', null, 99, false);
select t_ok((select rmin from public.cards where slug = 'rangetest') = 1
        and (select rmax from public.cards where slug = 'rangetest') = 3
        and (select crmin from public.cards where slug = 'rangetest') = 1
        and (select crmax from public.cards where slug = 'rangetest') = 3,
            'A CARD WRITTEN WITH A MINIMUM RANGE IS REPAIRED, not merely corrected by hand today');

-- `range` is the one number anybody sets, and the rest follow it.
update public.cards set range = 1 where slug = 'rangetest';
select t_ok((select rmax from public.cards where slug = 'rangetest') = 1
        and (select crmax from public.cards where slug = 'rangetest') = 1,
            'and setting the range alone moves all four, which is why the editor shows one box');
-- 0 and null both mean "I did not set this", so they fall back to the card's
-- own reach rather than making a hole. A range that is a NUMBER and still not
-- a number of tiles is the one that is refused.
update public.cards set range = 0 where slug = 'rangetest';
select t_ok((select range from public.cards where slug = 'rangetest') >= 1,
            'an unset range falls back rather than leaving a card that cannot reach anything');
select t_raises($$update public.cards set range = -1 where slug = 'rangetest'$$,
                'a range is 1 to 12', 'while a range that is not a number of tiles is refused');
delete from public.cards where slug = 'rangetest';
select set_config('request.jwt.claims', '', false);

-- ---- and it is true on the board, not only in the table ---------------------
-- The columns are only worth anything if the attack validation reads them, so
-- this walks a range-2 mage up to a foe and strikes it from ONE tile away --
-- the exact move that used to be refused with "too close for that unit".
delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('dd000000-0000-0000-0000-0000000000d1','r1@x.com','{"username":"mage"}'),
  ('dd000000-0000-0000-0000-0000000000d2','r2@x.com','{"username":"foe"}');

select set_config('app.uid','dd000000-0000-0000-0000-0000000000d1',false);
select public.set_deck(array['dereo','dione-grifo','mako','wuzu','eva']);
select set_config('app.uid','dd000000-0000-0000-0000-0000000000d2',false);
select public.set_deck(array['dereo','lium','himanta','fey','umiro']);

select set_config('app.uid','dd000000-0000-0000-0000-0000000000d1',false);
select id, code from public.create_match() \gset
select set_config('app.uid','dd000000-0000-0000-0000-0000000000d2',false);
select public.join_match(:'code');
select set_config('app.uid','dd000000-0000-0000-0000-0000000000d1',false);
select public.set_ready(:'id');
select set_config('app.uid','dd000000-0000-0000-0000-0000000000d2',false);
select public.set_ready(:'id');
select t_trees(:'id','[]'::jsonb);

select u->>'id' as mage from public.matches m, jsonb_array_elements(m.state->'units') u
 where m.id = :'id' and u->>'owner' = 'host' and u->>'slug' = 'dereo' limit 1 \gset
select u->>'id' as prey from public.matches m, jsonb_array_elements(m.state->'units') u
 where m.id = :'id' and u->>'owner' = 'guest' limit 1 \gset

-- Nose to nose.
select t_place(:'id', :'mage', 2, 2);
select t_place(:'id', :'prey', 2, 3);
select set_config('app.uid','dd000000-0000-0000-0000-0000000000d1',false);
select t_ok((select (u->>'hp')::int from public.matches m,
               jsonb_array_elements(m.state->'units') u
              where m.id = :'id' and u->>'id' = :'prey') > 0, 'the target is standing');
select public.submit_attack(:'id', :'mage', :'prey');
select t_ok((select (u->>'hp')::int from public.matches m,
               jsonb_array_elements(m.state->'units') u
              where m.id = :'id' and u->>'id' = :'prey')
            < (select (u->>'maxHp')::int from public.matches m,
                 jsonb_array_elements(m.state->'units') u
                where m.id = :'id' and u->>'id' = :'prey'),
            'A RANGE-2 MAGE CAN STRIKE THE THING STANDING NEXT TO IT — which it could not before 0030');
