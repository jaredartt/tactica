-- The match lifecycle, the clock, and the security boundary.
-- Combat itself lives in 04_roster.sql.
\set ON_ERROR_STOP on
\pset pager off

delete from public.matches;
delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'alice@x.com', '{"username":"alice"}'),
  ('22222222-2222-2222-2222-222222222222', 'bob@x.com',   '{"username":"bob"}'),
  ('33333333-3333-3333-3333-333333333333', 'carol@x.com', '{"username":"carol"}');

select t_ok((select count(*) from public.profiles) = 3, 'signup trigger created 3 profiles');
select t_ok((select count(*) from public.cards where is_active) = 6, 'six units in the roster');

-- ---- decks --------------------------------------------------------------
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select t_raises('select public.set_deck(array[''archer'',''mage'',''titan''])',
                'exactly 4', 'a deck is exactly four cards');
select t_raises('select public.set_deck(array[''archer'',''archer'',''mage'',''titan''])',
                'no repeats', 'no repeats in a deck');
select t_raises('select public.set_deck(array[''archer'',''mage'',''titan'',''dragon''])',
                'not in the roster', 'every card in a deck has to exist');
select public.set_deck(array['swordsman','archer','ninja','titan']);
select t_ok((select deck from public.profiles where id = auth.uid())
            = array['swordsman','archer','ninja','titan'], 'deck saved');

select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);
select public.set_deck(array['titan','mage','healer','swordsman']);

-- ---- alice opens a room -------------------------------------------------
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select id as mid from public.create_match() \gset

select t_ok((select status from public.matches where id=:'mid') = 'waiting', 'new match is waiting');
select t_ok((select jsonb_array_length(state->'units') from public.matches where id=:'mid') = 0,
            'no armies until someone joins');
select t_ok((select (state->'board'->>'w')::int from public.matches where id=:'mid') = 6,
            'the board is 6 wide');

-- ---- the map ------------------------------------------------------------
select t_ok((select jsonb_array_length(state->'obstacles') from public.matches where id=:'mid') = 6,
            'six trees, three a side');
select t_ok((select count(*) = 0 from public.matches m, jsonb_array_elements(m.state->'obstacles') o
              where m.id=:'mid'
                and ((o->>'x')::int in (0,5)) and ((o->>'y')::int in (0,5))),
            'no tree in a corner');
select t_ok((select count(*) filter (where (o->>'y')::int < 3) = 3
               and count(*) filter (where (o->>'y')::int >= 3) = 3
               from public.matches m, jsonb_array_elements(m.state->'obstacles') o
              where m.id=:'mid'),
            'three trees on each half');
select t_ok((select bool_and(public.cn_cheb((a.a->>'x')::int,(a.a->>'y')::int,
                                            (b.b->>'x')::int,(b.b->>'y')::int) >= 2)
               from public.matches m,
                    jsonb_array_elements(m.state->'obstacles') with ordinality a(a,i),
                    jsonb_array_elements(m.state->'obstacles') with ordinality b(b,j)
              where m.id=:'mid' and a.i < b.j),
            'no two trees touch');

select t_raises(format('select public.submit_move(%L,''h1'',1,1)', :'mid'),
                'not running', 'no moves while the room is empty');

-- ---- bob joins: deployment ---------------------------------------------
select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);
select code as mcode from public.matches where id = :'mid' \gset
select public.join_match(:'mcode');

select t_ok((select status from public.matches where id=:'mid') = 'deploying',
            'joining opens the deployment phase, not the match');
select t_ok((select jsonb_array_length(state->'units') from public.matches where id=:'mid') = 8,
            'four units a side are on the board from the start');
select t_ok((select count(*) = 4 from public.matches m, jsonb_array_elements(m.state->'units') u
              where m.id=:'mid' and u->>'owner'='host' and (u->>'y')::int >= 3),
            'the host army starts on the host half');
select t_ok((select count(*) = 4 from public.matches m, jsonb_array_elements(m.state->'units') u
              where m.id=:'mid' and u->>'owner'='guest' and (u->>'y')::int < 3),
            'the guest army starts on the guest half');
select t_ok(t_get(:'mid','g1','name') = 'Titan', 'the guest fields the deck they chose');
select t_ok(t_get(:'mid','h2','name') = 'Archer', 'the host fields the deck they chose');
select t_ok((select count(*) = 0 from public.matches m,
                 jsonb_array_elements(m.state->'units') u,
                 jsonb_array_elements(m.state->'obstacles') o
              where m.id=:'mid' and u->>'x'=o->>'x' and u->>'y'=o->>'y'),
            'nobody is standing in a tree');

select t_raises(format('select public.submit_move(%L,''g1'',1,1)', :'mid'),
                'not running', 'no moving until deployment ends');

select t_raises(format('select public.deploy_unit(%L,''g1'',2,4)', :'mid'),
                'not your half', 'you cannot deploy into the opponent half');
select t_raises(format('select public.deploy_unit(%L,''h1'',1,1)', :'mid'),
                'not your unit', 'you cannot deploy the opponent army');
select t_raises(format('select public.deploy_unit(%L,''g1'',9,9)', :'mid'),
                'off the board', 'deployment stays on the board');

select t_trees(:'mid', '[]'::jsonb);
select public.deploy_unit(:'mid', 'g1', 2, 2);
select t_ok(t_get(:'mid','g1','x') = '2' and t_get(:'mid','g1','y') = '2', 'unit deployed');

select t_place(:'mid', 'g2', 4, 2);
select public.deploy_unit(:'mid', 'g1', 4, 2);
select t_ok(t_get(:'mid','g1','x') = '4' and t_get(:'mid','g2','x') = '2',
            'dropping onto your own unit swaps the two');

select t_trees(:'mid', '[{"id":"t1","x":1,"y":1,"hp":30,"maxHp":30}]'::jsonb);
select t_raises(format('select public.deploy_unit(%L,''g1'',1,1)', :'mid'),
                'tree', 'you cannot deploy into a tree');

select set_config('app.uid', '33333333-3333-3333-3333-333333333333', false);
select t_raises(format('select public.deploy_unit(%L,''g1'',3,1)', :'mid'),
                'spectating', 'spectators cannot deploy');
select t_raises(format('select public.set_ready(%L)', :'mid'),
                'spectating', 'spectators cannot press ready');

-- ---- ready ---------------------------------------------------------------
select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);
select public.set_ready(:'mid');
select t_ok((select status from public.matches where id=:'mid') = 'deploying',
            'one player ready is not enough');
select t_raises(format('select public.deploy_unit(%L,''g1'',3,1)', :'mid'),
                'already ready', 'ready locks your half');

select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select public.set_ready(:'mid');
select t_ok((select status from public.matches where id=:'mid') = 'active', 'both ready starts the match');
select t_ok((select state->>'phase' from public.matches where id=:'mid') = 'battle', 'phase is battle');
select t_ok((select turn_deadline > now() from public.matches where id=:'mid'), 'turn clock started');
select t_ok((select state->>'turn' from public.matches where id=:'mid') = 'host', 'host acts first');
select t_raises(format('select public.deploy_unit(%L,''h1'',1,4)', :'mid'),
                'deployment is over', 'no redeploying once the match starts');

-- ---- movement -----------------------------------------------------------
select t_trees(:'mid', '[]'::jsonb);
select t_place(:'mid','h1',0,5); select t_place(:'mid','h2',1,5);
select t_place(:'mid','h3',2,5); select t_place(:'mid','h4',3,5);
select t_place(:'mid','g1',0,0); select t_place(:'mid','g2',1,0);
select t_place(:'mid','g3',2,0); select t_place(:'mid','g4',3,0);

select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);
select t_raises(format('select public.submit_move(%L,''g1'',0,1)', :'mid'),
                'not your turn', 'guest cannot act on the host turn');

select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select t_raises(format('select public.submit_move(%L,''g1'',0,1)', :'mid'),
                'not your unit', 'cannot move the opponent''s unit');
select t_raises(format('select public.submit_move(%L,''h1'',0,2)', :'mid'),
                'cannot reach', 'move range is enforced');
select t_raises(format('select public.submit_move(%L,''h1'',9,9)', :'mid'),
                'cannot reach', 'board bounds are enforced');
select t_raises(format('select public.submit_move(%L,''h1'',1,5)', :'mid'),
                'cannot reach', 'cannot stack two units on a tile');

select public.submit_move(:'mid', 'h1', 0, 3);
select t_ok(t_get(:'mid','h1','y') = '3', 'move applied');
select t_raises(format('select public.submit_move(%L,''h1'',0,4)', :'mid'),
                'already moved', 'one move per unit per turn');

select public.end_turn(:'mid');
select t_ok((select state->>'turn' from public.matches where id=:'mid') = 'guest', 'turn passed to guest');
select t_ok((select bool_and(not (u->>'moved')::boolean) from public.matches m,
             jsonb_array_elements(m.state->'units') u where m.id=:'mid'),
            'unit actions reset on turn change');

-- ---- the clock ----------------------------------------------------------
select set_config('app.uid', '33333333-3333-3333-3333-333333333333', false);
select public.force_timeout(:'mid');
select t_ok((select state->>'turn' from public.matches where id=:'mid') = 'guest',
            'force_timeout does nothing before the deadline');
select t_raises(format('select public.submit_move(%L,''g1'',0,1)', :'mid'),
                'spectating', 'spectators cannot move pieces');
select t_raises(format('select public.end_turn(%L)', :'mid'),
                'spectating', 'spectators cannot end a turn');

update public.matches set turn_deadline = now() - interval '5 seconds' where id = :'mid';
select public.force_timeout(:'mid');
select t_ok((select state->>'turn' from public.matches where id=:'mid') = 'host',
            'force_timeout passes the turn once time is up');

select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
update public.matches set turn_deadline = now() - interval '10 seconds' where id = :'mid';
select t_raises(format('select public.submit_move(%L,''h2'',1,4)', :'mid'),
                'time ran out', 'expired turns reject moves');
update public.matches set turn_deadline = now() + interval '30 seconds' where id = :'mid';

-- a deployment clock that runs out starts the match rather than stalling it
select id as m2 from public.create_match() \gset
select code as c2 from public.matches where id = :'m2' \gset
select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);
select public.join_match(:'c2');
update public.matches set turn_deadline = now() - interval '5 seconds' where id = :'m2';
select public.force_timeout(:'m2');
select t_ok((select status from public.matches where id=:'m2') = 'active',
            'deployment times out into a started match');

-- ---- win condition ------------------------------------------------------
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select t_place(:'mid','h1',0,1); select t_hp(:'mid','g1',1);
select t_place(:'mid','h2',1,1); select t_hp(:'mid','g2',1);
select t_place(:'mid','h3',2,1); select t_hp(:'mid','g3',1);
select t_place(:'mid','h4',3,1); select t_hp(:'mid','g4',1);
select t_dmg(:'mid','h1',40); select t_dmg(:'mid','h2',40);
select t_dmg(:'mid','h3',40); select t_dmg(:'mid','h4',40);
select t_set(:'mid','h1','rmin','1'::jsonb); select t_set(:'mid','h1','rmax','1'::jsonb);
select t_set(:'mid','h2','rmin','1'::jsonb); select t_set(:'mid','h2','rmax','1'::jsonb);
select t_set(:'mid','h3','rmin','1'::jsonb); select t_set(:'mid','h3','rmax','1'::jsonb);
select t_set(:'mid','h4','rmin','1'::jsonb); select t_set(:'mid','h4','rmax','1'::jsonb);

select public.submit_attack(:'mid','h1','g1');
select public.submit_attack(:'mid','h2','g2');
select public.submit_attack(:'mid','h3','g3');
select public.submit_attack(:'mid','h4','g4');

select t_ok((select status from public.matches where id=:'mid') = 'finished', 'match finished');
select t_ok((select winner from public.matches where id=:'mid') = 'host', 'host recorded as winner');
select t_ok((select jsonb_array_length(state->'units') from public.matches where id=:'mid') = 4,
            'destroyed units removed from the board');

-- ---- privilege checks ---------------------------------------------------
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

set role authenticated;
select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);

select t_raises(format('select public.advance_turn(%L, null)', :'mid'),
                'permission denied', 'advance_turn is not callable by players');
select t_raises(format('select public.cn_set_ready(%L, ''host'', true)', :'mid'),
                'permission denied', 'a player cannot force the other one ready');
select t_norows(format('update public.matches set state = ''{}''::jsonb where id = %L', :'mid'),
                'clients cannot write match state directly');
select t_raises('insert into public.cards (name) values (''Cheat'')',
                'policy', 'non-admins cannot add cards');
select t_norows('update public.profiles set username = ''alice2'' where id = ''11111111-1111-1111-1111-111111111111''',
                'cannot edit another player''s profile');

update public.profiles set is_admin = true
 where id = '22222222-2222-2222-2222-222222222222';
select t_ok((select is_admin from public.profiles
              where id = '22222222-2222-2222-2222-222222222222') = false,
            'cannot self-promote to admin');

reset role;
\echo '--- lifecycle and security: all assertions passed ---'
