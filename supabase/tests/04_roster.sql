-- Combat, terrain and the two distances -- played with the real roster.
-- The abilities that are unique to one card live in 07_abilities.sql.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@x.com', '{"username":"ann"}'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@x.com', '{"username":"ben"}');

-- ---- the roster reads back the way it was specified ---------------------
select t_ok((select hp=110 and mov=2 and rmin=1 and rmax=1 and crmin=1 and crmax=2
               and dmin=18 and dmax=26 from public.cards where slug='dione-grifo'),
            'Dione & Grifo');
select t_ok((select hp=120 and mov=1 and rmax=1 and dmin=30 and dmax=42 and tramples
               from public.cards where slug='wuzu'), 'Wuzu');
select t_ok((select hp=60 and mov=3 and rmax=1 and dmin=20 and dmax=30 and sneaks
               from public.cards where slug='mako'), 'Mako');
select t_ok((select hp=70 and mov=3 and rmax=1 and dmin=15 and dmax=22 and flies
               from public.cards where slug='lumea'), 'Lumea');
select t_ok((select hp=70 and mov=2 and rmin=2 and rmax=2 and crmin=1 and crmax=2
               and dmin=15 and dmax=25 and burns from public.cards where slug='dereo'), 'Dereo');
select t_ok((select hp=65 and mov=2 and rmin=2 and rmax=3 and crmin=3 and crmax=3
               and dmin=12 and dmax=20 from public.cards where slug='fey'), 'Fey');
select t_ok((select hp=70 and mov=3 and rmin=1 and rmax=2 and dmin=5 and dmax=15 and heals
               from public.cards where slug='eva'), 'Eva');
select t_ok((select hp=95 and mov=1 and rmin=1 and rmax=2 and dmin=10 and dmax=20
               and heals and cures from public.cards where slug='umiro'), 'Umiro');

select set_config('app.uid', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select public.set_deck(array['dione-grifo','dereo','mako','wuzu']);
select set_config('app.uid', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select public.set_deck(array['dereo','eva','umiro','lumea']);

select t_match('aaaaaaaa-0000-0000-0000-000000000001',
               'bbbbbbbb-0000-0000-0000-000000000002') as mid \gset
select set_config('app.uid', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t_trees(:'mid', '[]'::jsonb);
select t_park(:'mid', array['h1','h2','h3','h4','g1','g2','g3','g4']);

-- ---- movement is orthogonal; reach counts diagonals ---------------------
select t_reset(:'mid'); select t_place(:'mid','h4',2,5);       -- Wuzu, mov 1
select t_raises(format('select public.submit_move(%L,''h4'',3,4)', :'mid'),
                'cannot reach', 'one move does not cover a diagonal');
select public.submit_move(:'mid','h4',2,4);
select t_ok(t_get(:'mid','h4','y')='4', 'Wuzu moves its one tile');

select t_reset(:'mid'); select t_place(:'mid','h3',0,5);       -- Mako, mov 3
select public.submit_move(:'mid','h3',0,2);
select t_ok(t_get(:'mid','h3','y')='2', 'Mako crosses three tiles');

-- ---- exactly two, and who can answer it ---------------------------------
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','g1','g2','g3','g4']);
select t_place(:'mid','h2',0,3);          -- Dereo, reaches exactly 2
select t_place(:'mid','g4',0,2);          -- Lumea, one tile away
select t_raises(format('select public.submit_attack(%L,''h2'',''g4'')', :'mid'),
                'too close', 'Dereo cannot strike something in its face');
select t_place(:'mid','g4',0,0);
select t_raises(format('select public.submit_attack(%L,''h2'',''g4'')', :'mid'),
                'out of range', 'nor three tiles off');

select t_place(:'mid','g4',0,1);
select public.submit_attack(:'mid','h2','g4');
select t_ok(t_get(:'mid','h2','hp')::int = 70,
            'Lumea answers at one tile, so it cannot answer at two');
select t_ok(t_get(:'mid','g4','hp')::int between 45 and 55, 'Dereo rolled 15-25');
select t_ok(t_fx(:'mid','counter')::int = 0, 'and no counter is recorded');

select t_reset(:'mid'); select t_place(:'mid','g1',2,1); select t_place(:'mid','h2',2,3);
select public.submit_attack(:'mid','h2','g1');   -- Dereo on Dereo
select t_ok(t_get(:'mid','h2','hp')::int < 70, 'another Dereo DOES answer at two');

-- ---- melee reaches diagonally -------------------------------------------
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','g1','g2','g3','g4']);
select t_place(:'mid','h1',1,3); select t_place(:'mid','g4',2,2);
select t_hp(:'mid','g4',70);
select public.submit_attack(:'mid','h1','g4');   -- Dione & Grifo, diagonally
select t_ok(t_get(:'mid','g4','hp')::int < 70, 'Dione & Grifo hit diagonally');
select t_ok(t_get(:'mid','h1','hp')::int < 110, 'and are answered diagonally');

-- ---- burn -----------------------------------------------------------------
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','g1','g2','g3','g4']);
select t_place(:'mid','h2',2,3); select t_place(:'mid','g1',2,1);
select t_hp(:'mid','h2',70); select t_hp(:'mid','g1',70);
-- Dereo set that Dereo alight two assertions ago; put it out first, or this
-- section measures the previous test's fire rather than its own.
select t_set(:'mid','g1','burned','false'::jsonb);
select t_dmg(:'mid','h2',10);
select public.submit_attack(:'mid','h2','g1');
select t_ok(t_get(:'mid','g1','burned') = 'true', 'a burn is applied on hit');
select t_ok(t_get(:'mid','g1','hp')::int = 60, 'and costs nothing in the exchange that lit it');

select t_reset(:'mid'); select t_hp(:'mid','g1',60); select t_hp(:'mid','h2',70);
select t_dmg(:'mid','h2',10);
select public.submit_attack(:'mid','h2','g1');
select t_ok(t_fx(:'mid','burnTgt')::int = 5, 'a burned unit that counters burns for 5');
select t_ok(t_get(:'mid','g1','hp')::int = 45, '60 - 10 hit - 5 burn');

select t_reset(:'mid'); select t_set(:'mid','h1','burned','true'::jsonb);
select t_hp(:'mid','h1',110); select t_place(:'mid','h1',2,2); select t_place(:'mid','g1',2,1);
select public.submit_attack(:'mid','h1','g1');
select t_ok(t_fx(:'mid','burnAtk')::int = 5, 'a burned attacker burns for 5 too');
select t_set(:'mid','h1','burned','false'::jsonb);

-- ---- mending --------------------------------------------------------------
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','g1','g2','g3','g4']);
select t_raises(format('select public.submit_attack(%L,''h1'',''h2'')', :'mid'),
                'friendly fire', 'only a herbalist may target an ally');

select t_match('bbbbbbbb-0000-0000-0000-000000000002',
               'aaaaaaaa-0000-0000-0000-000000000001') as m2 \gset
select set_config('app.uid', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select t_trees(:'m2', '[]'::jsonb);
select t_park(:'m2', array['h1','h2','h3','h4','g1','g2','g3','g4']);
select t_ok(t_get(:'m2','h2','name') = 'Eva', 'ben hosts with Eva in slot 2');

select t_reset(:'m2'); select t_place(:'m2','h2',1,3); select t_place(:'m2','h4',1,4);
select t_hp(:'m2','h4',40);
select public.submit_attack(:'m2','h2','h4');
select t_ok(t_get(:'m2','h4','hp')::int between 45 and 55, 'Eva mends an ally for 5-15');
select t_ok(t_fx(:'m2','heal')::int > 0, 'recorded as a heal, not damage');

select t_reset(:'m2'); select t_hp(:'m2','h4',68);
select public.submit_attack(:'m2','h2','h4');
select t_ok(t_get(:'m2','h4','hp')::int = 70, 'mending never goes over maximum HP');

select t_reset(:'m2'); select t_place(:'m2','g1',1,1);
select public.submit_attack(:'m2','h2','g1');
select t_ok(t_get(:'m2','g1','hp')::int < 110, 'a herbalist can also hit, at two tiles');
select t_reset(:'m2'); select t_place(:'m2','g1',1,2);
select public.submit_attack(:'m2','h2','g1');
select t_ok(t_get(:'m2','g1','hp')::int < 110, 'and at one');

-- ---- trees ----------------------------------------------------------------
select set_config('app.uid', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','g1','g2','g3','g4']);

select t_trees(:'mid', '[{"id":"t1","x":0,"y":4,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'mid','h1',3,5); select t_place(:'mid','h2',4,5); select t_place(:'mid','h4',5,5);
select t_place(:'mid','h3',0,5);      -- Mako, mov 3
select t_raises(format('select public.submit_move(%L,''h3'',0,2)', :'mid'),
                'cannot reach', 'a tree makes a walker go around it');
select public.submit_move(:'mid','h3',1,3);
select t_ok(t_get(:'mid','h3','x')='1' and t_get(:'mid','h3','y')='3',
            'three steps around the tree is fine');
select t_reset(:'mid');
select t_raises(format('select public.submit_move(%L,''h3'',0,4)', :'mid'),
                'cannot reach', 'and you cannot stand in it');

select t_trees(:'mid', '[{"id":"t1","x":2,"y":2,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'mid','h2',2,3); select t_place(:'mid','g1',2,1);
select t_raises(format('select public.submit_attack(%L,''h2'',''g1'')', :'mid'),
                'tree is in the way', 'a tree in the line stops the shot');
select t_trees(:'mid', '[{"id":"t1","x":0,"y":2,"hp":30,"maxHp":30}]'::jsonb);
select public.submit_attack(:'mid','h2','g1');
select t_ok(t_get(:'mid','g1','hp')::int < 70, 'a tree off the line does not');

select t_reset(:'mid');
select t_trees(:'mid', '[{"id":"t1","x":2,"y":2,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'mid','h1',1,3); select t_place(:'mid','g4',1,2);
select t_hp(:'mid','g4',70);          -- it has been shot at all file; stand it back up
select public.submit_attack(:'mid','h1','g4');
select t_ok(t_get(:'mid','g4','hp')::int < 70, 'a neighbouring tree does not block a melee hit');

select t_reset(:'mid'); select t_hp(:'mid','h4',120);
select t_place(:'mid','h4',2,3);      -- Wuzu beside the tree
select t_ok(t_tree_hp(:'mid','t1') = 30, 'a tree has 30 HP');
select public.submit_attack(:'mid','h4','t1');
select t_ok((select jsonb_array_length(state->'obstacles') from public.matches where id=:'mid') = 0,
            'Wuzu fells a tree in one swing');
select t_ok(t_get(:'mid','h4','hp')::int = 120, 'a tree does not counter');

-- ---- decks fall back when the roster changes underneath them ------------
select t_ok(public.deck_of('bbbbbbbb-0000-0000-0000-000000000002')
            = array['dereo','eva','umiro','lumea'], 'a saved deck is used');
update public.cards set is_active = false where slug = 'dereo';
select t_ok(public.deck_of('bbbbbbbb-0000-0000-0000-000000000002') = public.default_deck(),
            'a deck holding a retired card falls back to the default');
update public.cards set is_active = true where slug = 'dereo';

\echo '--- combat, terrain and distance: all assertions passed ---'
