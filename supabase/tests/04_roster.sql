-- The roster, terrain and the combat rules that come with them.
\set ON_ERROR_STOP on
\pset pager off

delete from public.matches;
delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@x.com', '{"username":"ann"}'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@x.com', '{"username":"ben"}');

-- ---- the roster reads back the way it was specified ---------------------
select t_ok((select hp=80 and mov=2 and rmin=2 and rmax=2 and crmin=2 and crmax=2
               and dmin=10 and dmax=20 from public.cards where slug='archer'), 'Archer');
select t_ok((select hp=90 and mov=2 and rmin=1 and rmax=1 and crmin=1 and crmax=1
               and dmin=20 and dmax=30 from public.cards where slug='swordsman'), 'Swordsman');
select t_ok((select hp=60 and mov=3 and rmax=1 and crmin=1 and crmax=1
               and dmin=20 and dmax=30 from public.cards where slug='ninja'), 'Ninja');
select t_ok((select hp=100 and mov=1 and rmax=1 and crmin=1 and crmax=1
               and dmin=30 and dmax=40 from public.cards where slug='titan'), 'Titan');
select t_ok((select hp=70 and mov=2 and rmin=2 and rmax=2 and crmin=1 and crmax=2
               and dmin=15 and dmax=25 and burns from public.cards where slug='mage'), 'Mage');
select t_ok((select hp=80 and mov=2 and rmin=1 and rmax=2 and crmin=1 and crmax=2
               and dmin=5 and dmax=15 and heals from public.cards where slug='healer'), 'Healer');

select set_config('app.uid', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select public.set_deck(array['swordsman','archer','ninja','titan']);
select set_config('app.uid', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select public.set_deck(array['mage','healer','archer','swordsman']);

select t_match('aaaaaaaa-0000-0000-0000-000000000001',
               'bbbbbbbb-0000-0000-0000-000000000002') as mid \gset
select set_config('app.uid', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t_trees(:'mid', '[]'::jsonb);
select t_park(:'mid', array['h1','h2','h3','h4','g1','g2','g3','g4']);

-- ---- movement is orthogonal; reach counts diagonals ---------------------
select t_reset(:'mid'); select t_place(:'mid','h4',2,5);   -- Titan, mov 1
select t_raises(format('select public.submit_move(%L,''h4'',3,4)', :'mid'),
                'cannot reach', 'one move does not cover a diagonal');
select public.submit_move(:'mid','h4',2,4);
select t_ok(t_get(:'mid','h4','y')='4', 'the Titan moves its one tile');

select t_reset(:'mid'); select t_place(:'mid','h3',0,5);   -- Ninja, mov 3
select public.submit_move(:'mid','h3',0,2);
select t_ok(t_get(:'mid','h3','y')='2', 'the Ninja crosses three tiles');

-- ---- the Archer: exactly two, and only another Archer answers -----------
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','g1','g2','g3','g4']);
select t_place(:'mid','h2',0,3);            -- Archer
select t_place(:'mid','g4',0,2);            -- Swordsman, one tile away
select t_raises(format('select public.submit_attack(%L,''h2'',''g4'')', :'mid'),
                'too close', 'an Archer cannot shoot something in its face');
select t_place(:'mid','g4',0,0);
select t_raises(format('select public.submit_attack(%L,''h2'',''g4'')', :'mid'),
                'out of range', 'an Archer cannot shoot three tiles');

select t_place(:'mid','g4',0,1);
select public.submit_attack(:'mid','h2','g4');
select t_ok(t_get(:'mid','h2','hp')::int = 80,
            'a Swordsman cannot answer an Archer two tiles away');
select t_ok(t_get(:'mid','g4','hp')::int between 70 and 80, 'the Archer rolled 10-20');
select t_ok(t_fx(:'mid','counter')::int = 0, 'and the exchange records no counter');

select t_reset(:'mid'); select t_place(:'mid','g3',2,1); select t_place(:'mid','h2',2,3);
select public.submit_attack(:'mid','h2','g3');   -- Archer on Archer
select t_ok(t_get(:'mid','h2','hp')::int < 80, 'an Archer IS answered by another Archer');

-- ---- melee reaches diagonally ------------------------------------------
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','g1','g2','g3','g4']);
select t_place(:'mid','h1',1,3); select t_place(:'mid','g4',2,2);
select public.submit_attack(:'mid','h1','g4');    -- Swordsman, diagonal
select t_ok(t_get(:'mid','g4','hp')::int < 90, 'a Swordsman hits diagonally');
select t_ok(t_get(:'mid','h1','hp')::int < 90, 'and is countered diagonally');

-- ---- the Mage: burn, and a counter that covers one AND two --------------
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','g1','g2','g3','g4']);
select t_place(:'mid','h2',2,3); select t_place(:'mid','g1',2,1);   -- Archer vs Mage, 2 apart
select public.submit_attack(:'mid','h2','g1');
select t_ok(t_get(:'mid','h2','hp')::int < 80, 'the Mage counters from two tiles');

select t_reset(:'mid'); select t_hp(:'mid','h1',90);
select t_place(:'mid','h1',2,2); select t_place(:'mid','g1',2,1);   -- Swordsman vs Mage, adjacent
select public.submit_attack(:'mid','h1','g1');
select t_ok(t_get(:'mid','h1','hp')::int < 90, 'and from one');

-- the Mage sets what it hits alight, but the burn does not tax the counter
-- it makes in that same breath
select t_reset(:'mid'); select t_hp(:'mid','h1',90); select t_hp(:'mid','g1',70);
select t_set(:'mid','h1','burns','true'::jsonb); select t_dmg(:'mid','h1',10);
select t_place(:'mid','h1',2,2); select t_place(:'mid','g1',2,1);
select public.submit_attack(:'mid','h1','g1');
select t_ok(t_get(:'mid','g1','burned') = 'true', 'a burn is applied on hit');
select t_ok(t_get(:'mid','g1','hp')::int = 60, 'and costs nothing in the exchange that lit it');

-- from its next swing on, it pays
select t_reset(:'mid'); select t_hp(:'mid','g1',60); select t_hp(:'mid','h1',90);
select t_dmg(:'mid','h1',10);
select public.submit_attack(:'mid','h1','g1');
select t_ok(t_fx(:'mid','burnTgt')::int = 5, 'a burned unit that counters burns for 5');
select t_ok(t_get(:'mid','g1','hp')::int = 45, '60 - 10 hit - 5 burn');

select t_reset(:'mid'); select t_set(:'mid','h1','burned','true'::jsonb);
select t_hp(:'mid','h1',90); select t_hp(:'mid','g1',70);
select t_set(:'mid','h1','burns','false'::jsonb);
select public.submit_attack(:'mid','h1','g1');
select t_ok(t_fx(:'mid','burnAtk')::int = 5, 'a burned attacker burns for 5 too');
select t_set(:'mid','h1','burned','false'::jsonb);

-- ---- the Healer ---------------------------------------------------------
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','g1','g2','g3','g4']);
select t_raises(format('select public.submit_attack(%L,''h1'',''h2'')', :'mid'),
                'friendly fire', 'only a Healer may target an ally');

select t_match('bbbbbbbb-0000-0000-0000-000000000002',
               'aaaaaaaa-0000-0000-0000-000000000001') as m2 \gset
select set_config('app.uid', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select t_trees(:'m2', '[]'::jsonb);
select t_park(:'m2', array['h1','h2','h3','h4','g1','g2','g3','g4']);
select t_ok(t_get(:'m2','h2','name') = 'Healer', 'ben hosts with a Healer in slot 2');

select t_reset(:'m2'); select t_place(:'m2','h2',1,3); select t_place(:'m2','h4',1,4);
select t_hp(:'m2','h4',50);
select public.submit_attack(:'m2','h2','h4');
select t_ok(t_get(:'m2','h4','hp')::int between 55 and 65, 'a Healer mends an ally for 5-15');
select t_ok(t_fx(:'m2','heal')::int > 0, 'the mend is recorded as a heal, not damage');

select t_reset(:'m2'); select t_hp(:'m2','h4',88);
select public.submit_attack(:'m2','h2','h4');
select t_ok(t_get(:'m2','h4','hp')::int = 90, 'mending never goes over maximum HP');

select t_reset(:'m2'); select t_place(:'m2','g1',1,1);   -- two tiles from the Healer
select public.submit_attack(:'m2','h2','g1');
select t_ok(t_get(:'m2','g1','hp')::int < 90, 'a Healer can also hit, at two tiles');
select t_reset(:'m2'); select t_place(:'m2','g1',1,2);   -- and at one
select public.submit_attack(:'m2','h2','g1');
select t_ok(t_get(:'m2','g1','hp')::int < 90, 'and at one');

-- ---- trees --------------------------------------------------------------
select set_config('app.uid', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','g1','g2','g3','g4']);

-- a tree is a wall your feet have to go around
select t_trees(:'mid', '[{"id":"t1","x":0,"y":4,"hp":30,"maxHp":30}]'::jsonb);
-- the rest of the army out of the lane, so the only thing in the way is wood
select t_place(:'mid','h1',3,5); select t_place(:'mid','h2',4,5); select t_place(:'mid','h4',5,5);
select t_place(:'mid','h3',0,5);      -- Ninja, mov 3
select t_raises(format('select public.submit_move(%L,''h3'',0,2)', :'mid'),
                'cannot reach', 'a tree makes the unit walk around it');
select public.submit_move(:'mid','h3',1,3);
select t_ok(t_get(:'mid','h3','x')='1' and t_get(:'mid','h3','y')='3',
            'three steps around the tree is fine');
select t_reset(:'mid');
select t_raises(format('select public.submit_move(%L,''h3'',0,4)', :'mid'),
                'cannot reach', 'and you cannot stand in it');

-- and a wall the shot has to go around too
select t_trees(:'mid', '[{"id":"t1","x":2,"y":2,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'mid','h2',2,3); select t_place(:'mid','g3',2,1);
select t_raises(format('select public.submit_attack(%L,''h2'',''g3'')', :'mid'),
                'tree is in the way', 'a tree in the line stops the shot');
select t_trees(:'mid', '[{"id":"t1","x":0,"y":2,"hp":30,"maxHp":30}]'::jsonb);
select public.submit_attack(:'mid','h2','g3');
select t_ok(t_get(:'mid','g3','hp')::int < 80, 'a tree off the line does not');

-- melee never has anything between it
select t_reset(:'mid');
select t_trees(:'mid', '[{"id":"t1","x":2,"y":2,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'mid','h1',1,3); select t_place(:'mid','g4',1,2);
select public.submit_attack(:'mid','h1','g4');
select t_ok(t_get(:'mid','g4','hp')::int < 90, 'a neighbouring tree does not block a melee hit');

-- trees can be cut down, and they never hit back
select t_reset(:'mid'); select t_hp(:'mid','h4',100);
select t_place(:'mid','h4',2,3);   -- Titan, 30-40 a swing, next to the tree
select t_ok(t_tree_hp(:'mid','t1') = 30, 'a tree has 30 HP');
select public.submit_attack(:'mid','h4','t1');
select t_ok((select jsonb_array_length(state->'obstacles') from public.matches where id=:'mid') = 0,
            'a Titan fells a tree in one swing');
select t_ok(t_get(:'mid','h4','hp')::int = 100, 'a tree does not counter');

select t_reset(:'mid');
select t_trees(:'mid', '[{"id":"t2","x":2,"y":2,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'mid','h2',2,4);   -- Archer, 10-20, two tiles off
select public.submit_attack(:'mid','h2','t2');
select t_ok(t_tree_hp(:'mid','t2') between 10 and 20, 'an Archer can shoot a tree, and chips it');

-- ---- decks fall back when the roster changes underneath them ------------
select t_ok(public.deck_of('bbbbbbbb-0000-0000-0000-000000000002')
            = array['mage','healer','archer','swordsman'], 'a saved deck is used');
update public.cards set is_active = false where slug = 'mage';
select t_ok(public.deck_of('bbbbbbbb-0000-0000-0000-000000000002') = public.default_deck(),
            'a deck holding a retired card falls back to the default');
update public.cards set is_active = true where slug = 'mage';

\echo '--- roster, terrain and combat: all assertions passed ---'
