-- 0033: the five abilities, and the engine under them.
--
-- An ability SUBSTITUTES THE ATTACK -- one activation is still a unit's whole
-- go -- so most of what has to be asserted is that `submit_ability` is the
-- same citizen as `submit_attack`: same budget, same turn, same ownership,
-- same clock. The rest is the five themselves, and the two that are easiest to
-- get subtly wrong are Back to Back (which must hit your OWN units, because
-- that is the decision in it) and Strike Twice (which must fire on a counter
-- and on a parry's answer, not only on the attack).
\set ON_ERROR_STOP on
\pset pager off

set cn.force_parry = 'never'; set cn.force_crit = 'never';
set cn.force_twice = 'never'; set cn.force_mist = 'never';

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('ff000000-0000-0000-0000-0000000000f1','k1@x.com','{"username":"one"}'),
  ('ff000000-0000-0000-0000-0000000000f2','k2@x.com','{"username":"two"}');

select set_config('app.uid','ff000000-0000-0000-0000-0000000000f1',false);
select public.set_deck(array['dereo','dione-grifo','sinie','himanta','wuzu']);
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f2',false);
select public.set_deck(array['dereo','eva','mako','fey','lumea']);
select t_match('ff000000-0000-0000-0000-0000000000f1',
               'ff000000-0000-0000-0000-0000000000f2') as m \gset
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f1',false);
select t_trees(:'m','[]'::jsonb);
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);

select t_ok(t_get(:'m','h2','name') = 'Dione & Grifo'
        and t_get(:'m','h3','name') = 'Sinie'
        and t_get(:'m','h4','name') = 'Himanta'
        and t_get(:'m','h5','name') = 'Wuzu', 'the host fields the four that changed');
select t_ok(t_get(:'m','g2','name') = 'Eva' and t_get(:'m','g3','name') = 'Mako',
            'and the guest has Eva and a Rogue for her to shelter');

-- ---- the shell -------------------------------------------------------------
select t_ok(t_get(:'m','h1','abilityKind') is null, 'a Royal has no ability to use');
select t_raises(format('select public.submit_ability(%L,''h1'',null)', :'m'),
                'no ability', 'and asking is refused rather than ignored');
select t_raises(format('select public.submit_ability(%L,''g2'',null)', :'m'),
                'not your unit', 'nor can you use one of theirs');

select set_config('app.uid','ff000000-0000-0000-0000-0000000000f2',false);
select t_raises(format('select public.submit_ability(%L,''g2'',null)', :'m'),
                'not your turn', 'and not out of turn');
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f1',false);

-- ---- Back to Back ----------------------------------------------------------
-- The one with the decision in it: fifteen to EVERY adjacent tile, and "every"
-- includes your own. Four units around the pair, one of them theirs, one of
-- them two tiles off, and a tree.
select t_reset(:'m'); select t_noauras(:'m');
select t_trees(:'m','[{"id":"t1","x":3,"y":2,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'m','h2',2,2);                       -- the pair
select t_place(:'m','h3',2,3); select t_hp(:'m','h3',65);   -- an ALLY, next to them
select t_place(:'m','g3',1,2); select t_hp(:'m','g3',60);   -- a foe, next to them
select t_place(:'m','h5',2,0); select t_hp(:'m','h5',85);   -- two tiles off
select public.submit_ability(:'m','h2',null);

select t_ok(t_get(:'m','g3','hp')::int = 45, 'BACK TO BACK deals 15 to the foe beside them');
select t_ok(t_get(:'m','h3','hp')::int = 50,
            'AND 15 TO THEIR OWN ALLY — "all nearby tiles" means all of them');
select t_ok(t_get(:'m','h5','hp')::int = 85, 'and nothing at all two tiles away');
select t_ok(t_get(:'m','h2','hp')::int = t_get(:'m','h2','maxHp')::int,
            'the pair themselves are untouched');
select t_ok(t_tree_hp(:'m','t1') = 15, 'and the tree beside them takes it too');
select t_ok((select state->'fx'->>'kind' from public.matches where id=:'m') = 'ability',
            'the clients are told it was an ability, not an exchange');
-- Membership rather than a count: t_park puts the other six units down the
-- back columns and one of them could be standing next to the pair by luck. A
-- count would then be a test that passes on a coin flip.
select t_ok((select count(*) from jsonb_array_elements(
               (select state->'fx'->'hits' from public.matches where id=:'m')) e
              where e->>'id' in ('h3','g3')) = 2,
            'and who it landed on — the ally and the foe, in one go');
select t_ok((select count(*) from jsonb_array_elements(
               (select state->'fx'->'hits' from public.matches where id=:'m')) e
              where e->>'id' = 'h5') = 0,
            'and not the one two tiles away');

-- It costs the activation, exactly like a strike.
select t_raises(format('select public.submit_ability(%L,''h2'',null)', :'m'),
                'already had its go', 'AND IT SPENDS THE GO: no second ability from the same unit');
select t_raises(format('select public.submit_attack(%L,''h2'',''g3'')', :'m'),
                'already had its go', 'nor an attack after it — the ability IS the attack');

-- ---- Healing Petals --------------------------------------------------------
select t_reset(:'m'); select t_trees(:'m','[]'::jsonb);
select t_place(:'m','h3',0,0);                        -- Sinie, reach 3
select t_place(:'m','h5',0,2); select t_hp(:'m','h5',40);
select public.submit_ability(:'m','h3','h5');
select t_ok(t_get(:'m','h5','hp')::int = 70, 'HEALING PETALS gives an ally exactly 30');
select t_ok((select state->'fx'->'hits'->0->>'heal' from public.matches where id=:'m') = '30',
            'and says so as a heal rather than as damage');

-- Capped, and aimed at ONE.
select t_reset(:'m'); select t_hp(:'m','h5',75);
select public.submit_ability(:'m','h3','h5');
select t_ok(t_get(:'m','h5','hp')::int = 85, 'it never goes over a maximum');

-- Jared's reading of "a target": any unit at all.
select t_reset(:'m'); select t_place(:'m','g3',1,1); select t_hp(:'m','g3',20);
select public.submit_ability(:'m','h3','g3');
select t_ok(t_get(:'m','g3','hp')::int = 50,
            'AND IT WILL MEND AN ENEMY — "a target" is any target, which is what the card says');

select t_reset(:'m'); select t_place(:'m','h5',5,5);
select t_raises(format('select public.submit_ability(%L,''h3'',''h5'')', :'m'),
                'out of range', 'but not one past her reach');
select t_reset(:'m'); select t_place(:'m','h5',0,2);
select t_trees(:'m','[{"id":"t1","x":0,"y":1,"hp":30,"maxHp":30}]'::jsonb);
select t_raises(format('select public.submit_ability(%L,''h3'',''h5'')', :'m'),
                'tree is in the way', 'and not through a tree, the same as a shot');

-- ---- Slippery -------------------------------------------------------------
-- Himanta has no ability: Slippery is a passive, and the two are different
-- things on the card as well as in the engine.
select t_ok(t_get(:'m','h4','abilityKind') is null and t_get(:'m','h4','slippery') = 'true',
            'Himanta carries a PASSIVE, not an ability');

select t_reset(:'m'); select t_trees(:'m','[]'::jsonb); select t_noauras(:'m');
-- The parry is put on the RECEIVER at a certainty rather than forced globally,
-- and Himanta's own is turned off. Forcing the dice for the whole board makes
-- Himanta parry Mako's counter and answer it, which is three swings of noise
-- around the one fact this is about.
set cn.force_parry = 'never'; set cn.force_crit = 'never';
select t_place(:'m','h4',2,2); select t_place(:'m','g3',2,3);
select t_hp(:'m','h4',70); select t_full(:'m','g3'); select t_dmg(:'m','h4',20);
select t_set(:'m','g3','parryPct','100'::jsonb);   -- would catch anything
select t_set(:'m','h4','parryPct','0'::jsonb);
select public.submit_attack(:'m','h4','g3');
select t_ok(t_get(:'m','g3','hp')::int = 40,
            'NOTHING PARRIES A BLOW OF HIMANTA''S — not even a parrier at a certainty');
select t_ok(t_shape(:'m') not like '%parry%', 'and no parry is recorded at all');
select t_set(:'m','g3','parryPct','5'::jsonb); select t_set(:'m','h4','parryPct','5'::jsonb);

-- The mirror: a blow AT Himanta cannot crit.
set cn.force_parry = 'never'; set cn.force_crit = 'always';
select t_reset(:'m'); select t_full(:'m','h4'); select t_full(:'m','g3');
select t_dmg(:'m','g3',20); select t_set(:'m','g3','slippery','false'::jsonb);
select public.end_turn(:'m');
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f2',false);
select t_place(:'m','g3',2,3); select t_place(:'m','h4',2,2);
select public.submit_attack(:'m','g3','h4');
select t_ok(t_get(:'m','h4','hp')::int = 50,
            'and nothing crits Himanta either — 20 is 20, with crit forced on');
set cn.force_parry = 'never'; set cn.force_crit = 'never';

-- ---- Strike twice ----------------------------------------------------------
-- "A second hit when Himanta attacks, counters or parries." All three are one
-- thing in this engine -- a swing in the chain -- which is what 0020's uniform
-- loop bought without knowing it.
-- The turn is handed back by the side that holds it, which is the guest after
-- the mirror above.
select public.end_turn(:'m');
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f1',false);
select t_reset(:'m'); select t_noauras(:'m');
select t_place(:'m','h4',2,2); select t_place(:'m','g3',2,3);
select t_hp(:'m','h4',70); select t_full(:'m','g3');
select t_dmg(:'m','h4',20); select t_dmg(:'m','g3',20);
set cn.force_twice = 'always';
select public.submit_attack(:'m','h4','g3');
select t_ok(t_shape(:'m') like 'hit:h4,hit:h4%',
            'STRIKING TWICE: the attack is followed by a second swing from the same unit');
select t_ok(t_swi(:'m',1,'why') = 'twice', 'and it says which rule made it');
select t_ok(t_get(:'m','g3','hp')::int = 20, 'two blows of 20 off a 60-point Rogue');

-- and on the counter, which is the half that is easy to miss
select t_reset(:'m'); select t_noauras(:'m');
select t_place(:'m','h5',2,2); select t_place(:'m','h4',0,0);
select t_place(:'m','g3',2,3); select t_full(:'m','g3');
select t_hp(:'m','h5',85); select t_dmg(:'m','h5',20);
select t_set(:'m','g3','twicePct','100'::jsonb); select t_dmg(:'m','g3',20);
select public.submit_attack(:'m','h5','g3');
select t_ok(t_shape(:'m') like '%,hit:g3,hit:g3%',
            'AND ON THE COUNTER TOO — the answer is doubled the same way');
reset cn.force_twice; set cn.force_twice = 'never';

-- ---- the Mist --------------------------------------------------------------
select t_reset(:'m'); select t_noauras(:'m');
select public.end_turn(:'m');
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f2',false);
select t_ok(t_get(:'m','g2','abilityKind') = 'mist', 'Eva carries the mist');
select public.submit_ability(:'m','g2',null);
select t_ok((select state->'mist'->'guest'->>'t' from public.matches where id=:'m') = '2',
            'NATURE''S WHISPER puts two turns of cover over her side');
select t_ok((select state->'mist'->'guest'->>'pct' from public.matches where id=:'m') = '10',
            'at ten per cent, stored with it rather than read off her card later');
select t_ok((select state->'mist'->'host' from public.matches where id=:'m') is null,
            'and nothing at all over the other side');

-- A Rogue on that side dodges; a Mage on the same side does not.
set cn.force_mist = 'always';
select public.end_turn(:'m');
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f1',false);
select t_reset(:'m'); select t_noauras(:'m');
select t_place(:'m','h5',2,2); select t_place(:'m','g3',2,3);
select t_full(:'m','g3'); select t_dmg(:'m','h5',20);
select public.submit_attack(:'m','h5','g3');
select t_ok(t_get(:'m','g3','hp')::int = 60,
            'A ROGUE IN THE MIST TAKES NOTHING — the blow lands on empty air');
select t_ok(t_swi(:'m',0,'why') = 'mist', 'and the cinematic is told why');

select t_reset(:'m'); select t_noauras(:'m');
select t_place(:'m','h5',2,2); select t_place(:'m','g4',2,3);
select t_full(:'m','g4'); select t_dmg(:'m','h5',20);
select public.submit_attack(:'m','h5','g4');
select t_ok(t_get(:'m','g4','hp')::int < 85,
            'while a Mage standing in the same mist is hit like anybody');
reset cn.force_mist; set cn.force_mist = 'never';

-- It lifts. Two of the guest's turns, counted as they end.
select t_ok((select state->'mist'->'guest'->>'t' from public.matches where id=:'m') = '1',
            'one of the two turns is already spent');
select public.end_turn(:'m');
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f2',false);
select public.end_turn(:'m');
select t_ok((select state->'mist'->'guest'->>'t' from public.matches where id=:'m') = '0',
            'AND AFTER THE SECOND IT IS GONE');
select t_ok((select state->'log'->-1->>'text' from public.matches where id=:'m') like '%mist%'
         or (select count(*) from jsonb_array_elements(
               (select state->'log' from public.matches where id=:'m')) e
              where e->>'text' like '%mist lifts%') = 1,
            'and the log says so');
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f1',false);

-- ---- Regenerative Body -----------------------------------------------------
select t_reset(:'m'); select t_hp(:'m','h5',40);
select t_ok(t_get(:'m','h5','regenPct')::int = 5, 'Wuzu regenerates five per cent');
select public.end_turn(:'m');
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f2',false);
select public.end_turn(:'m');
select t_ok(t_get(:'m','h5','hp')::int = 44,
            'WUZU MENDS 5%% OF ITS MAXIMUM at the start of its own side''s turn');
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f1',false);

-- Two short of full, and the tick is four: the cap has to do real work here
-- rather than being masked by "do nothing when already full".
select t_reset(:'m'); select t_hp(:'m','h5',83);
select public.end_turn(:'m');
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f2',false);
select public.end_turn(:'m');
select t_ok(t_get(:'m','h5','hp')::int = 85, 'and NEVER PAST ITS MAXIMUM — 83 and a tick of 4 is 85');
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f1',false);

select t_reset(:'m'); select t_full(:'m','h5');
select public.end_turn(:'m');
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f2',false);
select public.end_turn(:'m');
select t_ok(t_get(:'m','h5','hp')::int = 85, 'and a full one is left alone entirely');
select set_config('app.uid','ff000000-0000-0000-0000-0000000000f1',false);
