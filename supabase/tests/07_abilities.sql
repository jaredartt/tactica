-- The four things the new roster can do that the old one could not.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('11110000-0000-0000-0000-00000000000a','p@x.com','{"username":"pia"}'),
  ('22220000-0000-0000-0000-00000000000b','q@x.com','{"username":"quin"}');

select t_ok((select count(*) from public.cards where is_active) = 8, 'eight cards in the roster');
select t_ok((select count(*) from public.cards where is_active and art_url is null) = 0,
            'every one of them has art');
select t_ok((select count(*) from public.cards where is_active and role = '') = 0,
            'and a class beside the name');

select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select public.set_deck(array['lumea','mako','umiro','wuzu']);
select set_config('app.uid','22220000-0000-0000-0000-00000000000b',false);
select public.set_deck(array['dione-grifo','dereo','fey','eva']);

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

-- ---- Wuzu walks through the wood ----------------------------------------
select t_reset(:'m');
select t_trees(:'m', '[{"id":"t1","x":2,"y":4,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'m','h2',5,0);
select t_place(:'m','h4',2,5);                          -- Wuzu, mov 1, tree ahead
select public.submit_move(:'m','h4',2,4);
select t_ok(t_get(:'m','h4','y') = '4', 'Wuzu steps onto the tree''s tile');
select t_ok((select jsonb_array_length(state->'obstacles') from public.matches where id=:'m') = 0,
            'and the tree is gone');
select t_ok((select state->'log'->-1->>'text' from public.matches where id=:'m')
              like '%comes down%', 'the log says so');

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
select public.submit_attack(:'m','h4','g1');
select t_ok(t_get(:'m','h4','hp')::int < 120, 'Wuzu takes the answer Mako did not');

-- the pair also answer from two tiles, which almost nothing else does
select t_reset(:'m'); select t_place(:'m','g1',2,1); select t_place(:'m','h4',2,3);
select t_set(:'m','h4','rmax','2'::jsonb); select t_hp(:'m','h4',120);
select public.submit_attack(:'m','h4','g1');
select t_ok(t_get(:'m','h4','hp')::int < 120, 'and from two tiles away');

-- ---- Umiro puts a fire out ----------------------------------------------
select t_reset(:'m');
select t_set(:'m','h1','burned','true'::jsonb); select t_hp(:'m','h1',40);
select t_place(:'m','h3',2,4); select t_place(:'m','h1',2,3);   -- Umiro beside Lumea
select t_ok(t_get(:'m','h3','cures') = 'true', 'Umiro cures');
select public.submit_attack(:'m','h3','h1');
select t_ok(t_get(:'m','h1','burned') = 'false', 'mending an ally puts the fire out');
select t_ok(t_get(:'m','h1','hp')::int between 50 and 60, 'and mends 10-20 while doing it');
select t_ok(t_fx(:'m','cured') = 'true', 'the clients are told, so they can show it');

-- Eva mends but does not cure
select t_reset(:'m');
select t_set(:'m','h1','burned','true'::jsonb); select t_hp(:'m','h1',40);
select t_set(:'m','h3','cures','false'::jsonb);        -- stand Eva in for Umiro
select public.submit_attack(:'m','h3','h1');
select t_ok(t_get(:'m','h1','burned') = 'true', 'a herbalist who does not cure leaves it burning');
select t_set(:'m','h3','cures','true'::jsonb);

-- ---- Fey reaches three, and only another three answers -------------------
select t_reset(:'m'); select t_park(:'m', array['h1','h2','h3','h4','g1','g2','g3','g4']);
select t_ok((select rmin=2 and rmax=3 and crmin=3 and crmax=3
               from public.cards where slug='fey'), 'Fey is 2-3, answering only at 3');
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
