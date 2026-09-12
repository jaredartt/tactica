-- The four things the new roster can do that the old one could not.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('11110000-0000-0000-0000-00000000000a','p@x.com','{"username":"pia"}'),
  ('22220000-0000-0000-0000-00000000000b','q@x.com','{"username":"quin"}');

select t_ok((select count(*) from public.cards where is_active) = 11, 'eleven cards in the roster');
select t_ok((select count(*) from public.cards where is_active and art_url is null) = 0,
            'every one of them has art');
select t_ok((select count(*) from public.cards where is_active and role = '') = 0,
            'and a class beside the name');

select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select public.set_deck(array['lumea','mako','umiro','wuzu','dereo']);
select set_config('app.uid','22220000-0000-0000-0000-00000000000b',false);
select public.set_deck(array['dione-grifo','dereo','fey','eva','umiro']);

select t_match('11110000-0000-0000-0000-00000000000a',
               '22220000-0000-0000-0000-00000000000b') as m \gset
select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select t_ok(t_get(:'m','h1','name') = 'Lumea', 'the deck you chose is the army you get');
select t_ok(t_get(:'m','h1','flies') = 'true', 'and the abilities came with it');

-- ---- Lumea goes over everything -----------------------------------------
select t_trees(:'m', '[{"id":"t1","x":2,"y":4,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'m','h1',2,5);           -- Lumea, mov 3, tree directly ahead
select t_place(:'m','h2',2,3);           -- Mako, a body directly beyond it
select t_place(:'m','h3',0,5); select t_place(:'m','h4',5,5);
select t_place(:'m','g1',0,0); select t_place(:'m','g2',1,0);
select t_place(:'m','g3',2,0); select t_place(:'m','g4',3,0);

select public.submit_move(:'m','h1',2,2);
select t_ok(t_get(:'m','h1','y') = '2',
            'Lumea crosses a tree AND a body and lands three tiles on');
select t_reset(:'m');
select t_raises(format('select public.submit_move(%L,''h1'',2,3)', :'m'),
                'cannot reach', 'but it still cannot land on somebody');
select t_raises(format('select public.submit_move(%L,''h1'',2,4)', :'m'),
                'cannot reach', 'nor in a tree');

-- a walker cannot do any of that
select t_reset(:'m'); select t_place(:'m','h1',5,0);   -- Lumea out of the way
select t_place(:'m','h2',2,5);                          -- Mako, mov 3, same lane
select t_raises(format('select public.submit_move(%L,''h2'',2,2)', :'m'),
                'cannot reach', 'Mako has to go round both');

-- ---- Wuzu goes OVER the wood now ----------------------------------------
-- It walked through it until 0031, felling it on the way. The spec has no
-- trampling in it anywhere and makes Wuzu a Flying unit, so the tree is
-- something it passes over and leaves standing. The old behaviour is asserted
-- as gone rather than deleted, so that anybody who brings trampling back finds
-- out here.
select t_reset(:'m');
select t_trees(:'m', '[{"id":"t1","x":2,"y":4,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'m','h2',5,0);
select t_place(:'m','h4',2,5);                          -- Wuzu, mov 3, tree ahead
select public.submit_move(:'m','h4',2,3);
select t_ok(t_get(:'m','h4','y') = '3', 'WUZU FLIES OVER THE TREE');
select t_ok((select jsonb_array_length(state->'obstacles') from public.matches where id=:'m') = 1,
            'and the tree is still standing — nothing tramples any more');
select t_reset(:'m'); select t_place(:'m','h4',2,5);
select t_raises(format('select public.submit_move(%L,''h4'',2,4)', :'m'),
                'cannot reach', 'and it cannot come down in one either');

-- ---- Mako is never answered ---------------------------------------------
select t_reset(:'m'); select t_trees(:'m', '[]'::jsonb);
select t_place(:'m','h2',2,3); select t_place(:'m','g1',2,2);   -- Mako vs Dione & Grifo
select t_hp(:'m','h2',60);
select public.submit_attack(:'m','h2','g1');
select t_ok(t_get(:'m','h2','hp')::int = 60,
            'Dione & Grifo answer at one tile -- but not a thief');
select t_ok(t_fx(:'m','counter')::int = 0, 'no counter is recorded at all');

-- and the pair DO answer anybody else
select t_reset(:'m'); select t_place(:'m','h4',2,3); select t_hp(:'m','h4',120);
select t_full(:'m','g1');   -- it has to survive to answer
select public.submit_attack(:'m','h4','g1');
select t_ok(t_get(:'m','h4','hp')::int < 120, 'Wuzu takes the answer Mako did not');

-- The pair used to answer from TWO tiles while striking at one -- a counter
-- reach of its own, which is the thing 0030 removed. "Range and reach IS THE
-- SAME thing": a unit answers what it could have struck and no further, so a
-- reach-1 pair does not reach a mage standing two away. The spec's ability for
-- Dione & Grifo ("Back to Back -- deals 15 to all nearby (Range 1) tiles")
-- never mentioned answering at two either; that was the engine's invention.
-- This is the old behaviour asserted as gone, deliberately, rather than
-- deleted -- so that anybody who brings it back finds out here.
select t_reset(:'m'); select t_place(:'m','g1',2,1); select t_place(:'m','h4',2,3);
select t_set(:'m','h4','rmax','2'::jsonb); select t_hp(:'m','h4',120);
select t_full(:'m','g1');
select public.submit_attack(:'m','h4','g1');
select t_ok(t_get(:'m','h4','hp')::int = 120,
            'AND NOT FROM TWO: since 0030 a unit answers only what it could have struck');

-- ---- Umiro puts a fire out ----------------------------------------------
select t_reset(:'m');
select t_set(:'m','h1','burned','true'::jsonb); select t_hp(:'m','h1',40);
select t_place(:'m','h3',2,4); select t_place(:'m','h1',2,3);   -- Umiro beside Lumea
select t_ok(t_get(:'m','h3','cures') = 'true', 'Umiro cures');
select public.submit_attack(:'m','h3','h1');
select t_ok(t_get(:'m','h1','burned') = 'false', 'mending an ally puts the fire out');
-- 20-30 since 0031: the spec gives Umiro a 25 where the live roster had 15.
select t_ok(t_get(:'m','h1','hp')::int between 60 and 70, 'and mends 20-30 while doing it');
select t_ok(t_fx(:'m','cured') = 'true', 'the clients are told, so they can show it');

-- Eva mends but does not cure
select t_reset(:'m');
select t_set(:'m','h1','burned','true'::jsonb); select t_hp(:'m','h1',40);
select t_set(:'m','h3','cures','false'::jsonb);        -- stand Eva in for Umiro
select public.submit_attack(:'m','h3','h1');
select t_ok(t_get(:'m','h1','burned') = 'true', 'a herbalist who does not cure leaves it burning');
select t_set(:'m','h3','cures','true'::jsonb);

-- ---- Fey reaches three, and only another three answers -------------------
select t_reset(:'m'); select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
-- Fey was 2-3, answering only at 3, which meant a mage with a sword at its
-- throat could neither strike back nor be answered. Since 0030 a range is one
-- number and it starts at 1: Fey reaches 1, 2 and 3, and answers across all
-- three.
select t_ok((select rmin=1 and rmax=3 and crmin=1 and crmax=3 and range=3
               from public.cards where slug='fey'),
            'FEY REACHES 1, 2 AND 3, and answers across all three');
select t_place(:'m','g3',2,2); select t_place(:'m','h4',2,5);   -- Fey vs Wuzu, three apart
select t_set(:'m','g3','rmax','3'::jsonb);
select set_config('app.uid','22220000-0000-0000-0000-00000000000b',false);
select t_raises(format('select public.submit_attack(%L,''g3'',''h4'')', :'m'),
                'not your turn', 'and it is still the host''s turn');

select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select t_raises(format('select public.submit_attack(%L,''h4'',''g3'')', :'m'),
                'out of range', 'Wuzu cannot reach three tiles to answer it');

-- ---- the bot inherits all of it -----------------------------------------
select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
-- ---- Lium answers first -------------------------------------------------
select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select public.set_deck(array['lium','himanta','mako','wuzu','dereo']);
select set_config('app.uid','22220000-0000-0000-0000-00000000000b',false);
select public.set_deck(array['dione-grifo','dereo','eva','fey','umiro']);
select t_match('22220000-0000-0000-0000-00000000000b',
               '11110000-0000-0000-0000-00000000000a') as p \gset
select set_config('app.uid','22220000-0000-0000-0000-00000000000b',false);
select t_trees(:'p', '[]'::jsonb);
select t_park(:'p', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'p','g1','name') = 'Lium', 'the guest fields Lium in slot 1');
select t_ok(t_get(:'p','g1','parries') = 'true', 'and it carries the flag');

-- an attacker that survives the answer still lands its blow
select t_reset(:'p'); select t_place(:'p','h1',2,2); select t_place(:'p','g1',2,3);
select t_hp(:'p','h1',110); select t_full(:'p','g1');
select public.submit_attack(:'p','h1','g1');
select t_ok(t_get(:'p','g1','hp')::int < 80, 'a survivor still gets its hit in');
select t_ok(t_get(:'p','h1','hp')::int < 110, 'and still takes the answer');

-- an attacker the answer kills never lands it at all
select t_reset(:'p'); select t_place(:'p','h1',2,2); select t_place(:'p','g1',2,3);
select t_hp(:'p','h1',8); select t_full(:'p','g1');
select public.submit_attack(:'p','h1','g1');
select t_ok(not t_alive(:'p','h1'), 'Lium kills the attacker with the answer');
-- 85 since 0031; the spec's Lium, where the live roster had 80.
select t_ok(t_get(:'p','g1','hp')::int = 85,
            'and the blow it was answering never lands -- Lium is untouched');
select t_ok(t_fx(:'p','dmg')::int = 0, 'recorded as no damage dealt');
select t_ok(t_fx(:'p','parry') = 'true', 'and flagged as a parry');

-- ---- Himanta glides ------------------------------------------------------
select t_reset(:'p');
select public.end_turn(:'p');                       -- hand the turn to the guest
select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select t_park(:'p', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'p','g2','name') = 'Himanta', 'the guest fields Himanta in slot 2');

-- Himanta flew until 0031 and this block asserted that it crossed trees and
-- bodies. The spec makes it a ROGUE -- flight belongs to the Flying class now
-- -- so it is on the ground with everybody else, and the old behaviour is
-- asserted as gone rather than deleted.
select t_trees(:'p', '[{"id":"t1","x":3,"y":4,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'p','g2',3,5);       -- Himanta, mov 2, a tree directly ahead
select t_place(:'p','g3',2,5);       -- and the only way round it blocked
select t_raises(format('select public.submit_move(%L,''g2'',3,3)', :'p'),
                'cannot reach', 'HIMANTA IS A ROGUE NOW, and walks: the tree is in its way');

select t_reset(:'p'); select t_place(:'p','g2',3,5); select t_place(:'p','g3',0,5);
select public.submit_move(:'p','g2',4,4);
select t_ok(t_get(:'p','g2','x') = '4' and t_get(:'p','g2','y') = '4',
            'and goes round it like anybody else when there is a way round');

select t_reset(:'p'); select t_place(:'p','g2',3,5);
select t_raises(format('select public.submit_move(%L,''g2'',3,4)', :'p'),
                'cannot reach', 'and still cannot stand in a tree');

-- Range 1 since 0031, where the live roster gave it two.
-- h1 is not on the board any more; it walked into the parry two tests ago
select t_reset(:'p'); select t_trees(:'p', '[]'::jsonb);
select t_place(:'p','g2',2,2); select t_place(:'p','h2',2,4);
select t_full(:'p','h2');
select t_raises(format('select public.submit_attack(%L,''g2'',''h2'')', :'p'),
                'out of range', 'and it no longer strikes from two tiles away');
select t_place(:'p','h2',2,3);
select public.submit_attack(:'p','g2','h2');
select t_ok(t_get(:'p','h2','hp')::int < t_get(:'p','h2','maxHp')::int,
            'but it strikes what is next to it');

select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
-- ---- Sinie mends everyone at once ---------------------------------------
select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select public.set_deck(array['sinie','mako','wuzu','lumea','dereo']);
select set_config('app.uid','22220000-0000-0000-0000-00000000000b',false);
select public.set_deck(array['dione-grifo','dereo','eva','fey','umiro']);
select t_match('11110000-0000-0000-0000-00000000000a',
               '22220000-0000-0000-0000-00000000000b') as b \gset
select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select t_trees(:'b', '[]'::jsonb);
select t_park(:'b', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'b','h1','name') = 'Sinie', 'the host fields Sinie in slot 1');
select t_ok(t_get(:'b','h1','blooms') = 'true', 'and she carries the flag');

-- three allies hurt: one clicked, one in reach, one out of it
select t_reset(:'b');
-- Sinie reaches THREE since 0031, and a 6x6 board has no tile further than
-- three from the middle -- so she starts in the corner, or "out of reach"
-- cannot exist to be tested.
select t_place(:'b','h1',0,0);          -- Sinie, reach 1-3
select t_place(:'b','h2',0,1);          -- clicked
select t_place(:'b','h3',1,1);          -- in reach, not clicked
select t_place(:'b','h4',5,5);          -- far away
select t_hp(:'b','h2',10); select t_hp(:'b','h3',10); select t_hp(:'b','h4',10);
select public.submit_attack(:'b','h1','h2');
select t_ok(t_get(:'b','h2','hp')::int > 10, 'the ally you clicked is mended');
select t_ok(t_get(:'b','h3','hp')::int > 10, 'and so is the one merely standing near her');
select t_ok(t_get(:'b','h4','hp')::int = 10, 'but not one outside her reach');
select t_ok(t_get(:'b','h2','hp')::int = t_get(:'b','h3','hp')::int,
            'one roll, spent on each of them -- a lucky roll is lucky once');
select t_ok(jsonb_array_length(t_fx(:'b','bloom')::jsonb) = 1,
            'the clients are told who else was caught in it');

-- a full ally is not counted
select t_reset(:'b'); select t_hp(:'b','h2',10);
select t_full(:'b','h3'); select t_full(:'b','h4');
select public.submit_attack(:'b','h1','h2');
select t_ok(jsonb_array_length(t_fx(:'b','bloom')::jsonb) = 0,
            'nobody at full health is swept up in it');

-- a tree between them blocks the bloom, the same as a shot
select t_reset(:'b'); select t_hp(:'b','h2',10); select t_hp(:'b','h3',10);
select t_full(:'b','h4');
select t_trees(:'b', '[{"id":"t1","x":3,"y":2,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'b','h3',4,2);
select public.submit_attack(:'b','h1','h2');
select t_ok(t_get(:'b','h3','hp')::int = 10, 'and wood stops it, the same as an arrow');

-- an ordinary healer still mends exactly one
select t_reset(:'b'); select t_trees(:'b', '[]'::jsonb);
select public.end_turn(:'b');            -- still the host's to give away
select set_config('app.uid','22220000-0000-0000-0000-00000000000b',false);
select t_ok(t_get(:'b','g3','name') = 'Eva', 'the guest fields Eva');
select t_park(:'b', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_place(:'b','g3',2,2); select t_place(:'b','g1',2,3); select t_place(:'b','g2',3,1);
select t_hp(:'b','g1',10); select t_hp(:'b','g2',10);
select public.submit_attack(:'b','g3','g1');
select t_ok(t_get(:'b','g1','hp')::int > 10 and t_get(:'b','g2','hp')::int = 10,
            'Eva mends the one she was pointed at and nobody else');
select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);

select id as bm from public.create_bot_match(3) \gset
select public.set_ready(:'bm');
do $$
declare i int := 0; mid uuid := (select id from public.matches where bot is not null
                                  order by created_at desc limit 1); st text;
begin
  perform set_config('app.uid', '11110000-0000-0000-0000-00000000000a', false);
  loop
    select status into st from public.matches where id = mid;
    -- generous: the bot draws four at random, and a hand of herbalists takes
    -- a long time to finish somebody who is standing still
    exit when st <> 'active' or i > 2000;
    if (select state->>'turn' from public.matches where id = mid) = 'guest'
      then perform public.bot_step(mid);
      else perform public.end_turn(mid);
    end if;
    i := i + 1;
  end loop;
  raise notice 'PASS  RUTHLESS plays the new roster to a finish (% steps, %)', i, st;
end $$;
select t_ok((select status from public.matches where id=:'bm') = 'finished'
        and (select winner from public.matches where id=:'bm') = 'guest',
            'and it still wins against somebody who never moves');
select t_ok((select count(*) = 0 from public.matches m,
                  jsonb_array_elements(m.state->'units') u,
                  jsonb_array_elements(m.state->'obstacles') o
              where m.id=:'bm' and u->>'x'=o->>'x' and u->>'y'=o->>'y'),
            'and never left anybody standing inside a tree');

\echo '--- the roster and its abilities: all assertions passed ---'
