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
select t_ok((select count(*) from public.cards where is_active) = 11, 'eleven units in the roster');

-- ---- decks --------------------------------------------------------------
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select t_raises('select public.set_deck(array[''dereo'',''eva'',''wuzu''])',
                'exactly 5', 'a team is exactly five cards');
select t_raises('select public.set_deck(array[''dereo'',''dereo'',''eva'',''wuzu'',''mako''])',
                'no repeats', 'no repeats in a team');
select t_raises('select public.set_deck(array[''dereo'',''eva'',''wuzu'',''mako'',''dragon''])',
                'not in the roster', 'every card in a team has to exist');
select public.set_deck(array['dione-grifo','dereo','mako','wuzu','eva']);
select t_ok((select deck from public.profiles where id = auth.uid())
            = array['dione-grifo','dereo','mako','wuzu','eva'], 'team saved');

select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);
select public.set_deck(array['wuzu','dereo','eva','dione-grifo','mako']);

-- ---- alice opens a room -------------------------------------------------
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select id as mid from public.create_match() \gset

select t_ok((select status from public.matches where id=:'mid') = 'waiting', 'new match is waiting');
select t_ok((select jsonb_array_length(state->'units') from public.matches where id=:'mid') = 0,
            'no armies until someone joins');
select t_ok((select (state->'board'->>'w')::int from public.matches where id=:'mid') = 6,
            'the board is 6 wide');
select t_ok((select (state->'board'->>'h')::int from public.matches where id=:'mid') = 8,
            'the board is 8 tall');

-- ---- the map ------------------------------------------------------------
select t_ok((select jsonb_array_length(state->'obstacles') from public.matches where id=:'mid') = 8,
            'eight trees, four a side');
select t_ok((select count(*) = 0 from public.matches m, jsonb_array_elements(m.state->'obstacles') o
              where m.id=:'mid'
                and ((o->>'x')::int in (0,5)) and ((o->>'y')::int in (0,7))),
            'no tree in a corner');
-- The halves are rows since 0019, so the home rows are 0 and 7. Nothing may
-- stand in either: that is where the armies deploy, and a tree there costs
-- somebody a starting square.
select t_ok((select count(*) = 0 from public.matches m, jsonb_array_elements(m.state->'obstacles') o
              where m.id=:'mid' and (o->>'y')::int in (0, 7)),
            'no tree on either home row');
select t_ok((select count(*) filter (where (o->>'y')::int < 4) = 4
               and count(*) filter (where (o->>'y')::int >= 4) = 4
               from public.matches m, jsonb_array_elements(m.state->'obstacles') o
              where m.id=:'mid'),
            'four trees on each half');
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

-- The whole point: while you are arranging your team, NOBODY's team is in the
-- row every signed-in player can read.
select t_ok((select jsonb_array_length(state->'units') from public.matches where id=:'mid') = 0,
            'no army is in the readable match row during deployment');
select t_ok(t_dcount(:'mid','host') = 5 and t_dcount(:'mid','guest') = 5,
            'both armies exist, one private row each');
select t_ok((select count(*) = 5 from public.match_deploy d, jsonb_array_elements(d.units) u
              where d.match_id=:'mid' and d.side='host' and (u->>'y')::int < 4),
            'the host army starts at the bottom');
select t_ok((select count(*) = 5 from public.match_deploy d, jsonb_array_elements(d.units) u
              where d.match_id=:'mid' and d.side='guest' and (u->>'y')::int >= 4),
            'the guest army starts at the top');
select t_ok(t_dget(:'mid','guest','g1','name') = 'Wuzu', 'the guest fields the deck they chose');
select t_ok(t_dget(:'mid','host','h2','name') = 'Dereo', 'the host fields the deck they chose');
select t_ok((select count(*) = 0 from public.match_deploy d,
                 jsonb_array_elements(d.units) u, public.matches m,
                 jsonb_array_elements(m.state->'obstacles') o
              where d.match_id=:'mid' and m.id=:'mid'
                and u->>'x'=o->>'x' and u->>'y'=o->>'y'),
            'nobody is standing in a tree');

select t_raises(format('select public.submit_move(%L,''g1'',1,1)', :'mid'),
                'not running', 'no moving until deployment ends');

-- y=2 is the host's ground now, whatever the column
select t_raises(format('select public.deploy_unit(%L,''g1'',4,2)', :'mid'),
                'not your half', 'you cannot deploy into the opponent half');
select t_raises(format('select public.deploy_unit(%L,''h1'',1,5)', :'mid'),
                'not your unit', 'you cannot deploy the opponent army');
select t_raises(format('select public.deploy_unit(%L,''g1'',9,9)', :'mid'),
                'off the board', 'deployment stays on the board');

-- Park the guest's five along a known row so the squares used below are
-- free whatever the opening formation happens to be. The guest holds rows
-- 4-7 since 0019, so row 7 is their back rank and row 4 their near one.
select t_trees(:'mid', '[]'::jsonb);
select t_dplace(:'mid','guest','g1',0,7), t_dplace(:'mid','guest','g2',1,7),
       t_dplace(:'mid','guest','g3',4,7), t_dplace(:'mid','guest','g4',5,7),
       t_dplace(:'mid','guest','g5',5,6);
select t_ok(public.deploy_unit(:'mid','g1',3,4) is not null,
            'the near row of your own side is yours too');
select public.deploy_unit(:'mid', 'g1', 3, 5);
select t_ok(t_dget(:'mid','guest','g1','x') = '3' and t_dget(:'mid','guest','g1','y') = '5',
            'unit deployed');

select t_dplace(:'mid', 'guest', 'g2', 4, 5);
select public.deploy_unit(:'mid', 'g1', 4, 5);
select t_ok(t_dget(:'mid','guest','g1','x') = '4' and t_dget(:'mid','guest','g2','x') = '3',
            'dropping onto your own unit swaps the two');

select t_trees(:'mid', '[{"id":"t1","x":4,"y":6,"hp":30,"maxHp":30}]'::jsonb);
select t_raises(format('select public.deploy_unit(%L,''g1'',4,6)', :'mid'),
                'tree', 'you cannot deploy into a tree');

select set_config('app.uid', '33333333-3333-3333-3333-333333333333', false);
select t_raises(format('select public.deploy_unit(%L,''g1'',4,1)', :'mid'),
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
select t_ok((select jsonb_array_length(state->'units') from public.matches where id=:'mid') = 10,
            'and that is the moment both armies appear on the board');
select t_ok((select state->>'phase' from public.matches where id=:'mid') = 'battle', 'phase is battle');
select t_ok((select turn_deadline > now() from public.matches where id=:'mid'), 'turn clock started');
select t_ok((select state->>'turn' from public.matches where id=:'mid') = 'host', 'host acts first');
select t_raises(format('select public.deploy_unit(%L,''h1'',1,4)', :'mid'),
                'deployment is over', 'no redeploying once the match starts');

-- ---- movement -----------------------------------------------------------
select t_trees(:'mid', '[]'::jsonb);
select t_place(:'mid','h1',0,5); select t_place(:'mid','h2',1,5);
select t_place(:'mid','h3',2,5); select t_place(:'mid','h4',3,5);
select t_place(:'mid','h5',4,5);
select t_place(:'mid','g1',0,0); select t_place(:'mid','g2',1,0);
select t_place(:'mid','g3',2,0); select t_place(:'mid','g4',3,0);
-- The fifth has to be placed too. Left where deployment put it, it sometimes
-- landed in the lane h1 walks up two assertions from here.
select t_place(:'mid','g5',4,0);

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
-- Both sides placed, not just the attackers: with five a side the opening
-- formation no longer leaves the far column empty, so "wherever they happen
-- to be standing" stopped being within anybody's reach.
select t_place(:'mid','h1',0,1); select t_place(:'mid','g1',0,2); select t_hp(:'mid','g1',1);
select t_place(:'mid','h2',1,1); select t_place(:'mid','g2',1,2); select t_hp(:'mid','g2',1);
select t_place(:'mid','h3',2,1); select t_place(:'mid','g3',2,2); select t_hp(:'mid','g3',1);
select t_place(:'mid','h4',3,1); select t_place(:'mid','g4',3,2); select t_hp(:'mid','g4',1);
select t_place(:'mid','h5',4,1); select t_place(:'mid','g5',4,2); select t_hp(:'mid','g5',1);
select t_dmg(:'mid','h1',40); select t_dmg(:'mid','h2',40);
select t_dmg(:'mid','h3',40); select t_dmg(:'mid','h4',40); select t_dmg(:'mid','h5',40);
select t_set(:'mid','h1','rmin','1'::jsonb); select t_set(:'mid','h1','rmax','1'::jsonb);
select t_set(:'mid','h2','rmin','1'::jsonb); select t_set(:'mid','h2','rmax','1'::jsonb);
select t_set(:'mid','h3','rmin','1'::jsonb); select t_set(:'mid','h3','rmax','1'::jsonb);
select t_set(:'mid','h4','rmin','1'::jsonb); select t_set(:'mid','h4','rmax','1'::jsonb);
select t_set(:'mid','h5','rmin','1'::jsonb); select t_set(:'mid','h5','rmax','1'::jsonb);

-- g2 is Dereo, the guest's crown, and he goes LAST on purpose: since 0018 a
-- fallen royal ends the match on its own, so felling him first would finish
-- the game with four guests still standing and this test would no longer be
-- about the last body on the board. The crown has its own section below.
-- t_reset between the blows: this section is about the win condition, not
-- about the two-activation budget (0019), and five kills is more goes than a
-- turn now holds. The budget itself is 10_board.sql's business.
select public.submit_attack(:'mid','h1','g1'); select t_reset(:'mid');
select public.submit_attack(:'mid','h3','g3'); select t_reset(:'mid');
select public.submit_attack(:'mid','h4','g4'); select t_reset(:'mid');
select public.submit_attack(:'mid','h5','g5'); select t_reset(:'mid');
select t_ok((select status from public.matches where id=:'mid') = 'active',
            'four down and the fifth still standing is not a win');
select public.submit_attack(:'mid','h2','g2');

select t_ok((select status from public.matches where id=:'mid') = 'finished', 'match finished');
select t_ok((select winner from public.matches where id=:'mid') = 'host', 'host recorded as winner');
select t_ok((select jsonb_array_length(state->'units') from public.matches where id=:'mid') = 5,
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
-- A card that would otherwise be FINE, on purpose. It used to be
-- `(name) values ('Cheat')` -- a card with no slug -- and once 0025 added the
-- editor's guard rails that was refused by the slug check before the policy
-- ever got a look at it. The assertion still passed, for the wrong reason: it
-- was testing the validator, not the wall.
select t_raises('insert into public.cards (slug, name, accent) values (''cheat'', ''Cheat'', ''#2f4bff'')',
                'policy', 'non-admins cannot add cards');
-- bob is the guest in both rooms, so he should see guest rows and, however
-- he asks, never a host one.
select t_ok((select count(*) from public.match_deploy where side = 'host') = 0
        and (select count(*) from public.match_deploy where side = 'guest') > 0,
            'a player sees their own deployment and never the other side''s');
select t_norows('update public.profiles set username = ''alice2'' where id = ''11111111-1111-1111-1111-111111111111''',
                'cannot edit another player''s profile');

update public.profiles set is_admin = true
 where id = '22222222-2222-2222-2222-222222222222';
select t_ok((select is_admin from public.profiles
              where id = '22222222-2222-2222-2222-222222222222') = false,
            'cannot self-promote to admin');

reset role;
\echo '--- lifecycle and security: all assertions passed ---'
