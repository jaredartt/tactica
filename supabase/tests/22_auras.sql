-- 0031: the crowns, and the hook that was waiting for them.
--
-- `cn_damage` has taken a bonus and a resistance since 0018, with a comment
-- saying they "are the hook the royal passives and the class resistances will
-- hang on" -- and for thirteen migrations every caller passed zero. This is
-- the file that makes them mean something.
--
-- The important assertions are the NEGATIVE ones. A resistance that applies to
-- everything is not a resistance, it is a health bar; the whole of what makes
-- King Dereo's aura a decision is that it reads the attacker's class and the
-- defender's side, and both of those are easy to get subtly wrong in a way
-- that still looks like it works.
\set ON_ERROR_STOP on
\pset pager off

set cn.force_parry = 'never'; set cn.force_crit = 'never';

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('ee000000-0000-0000-0000-0000000000e1','a1@x.com','{"username":"crowned"}'),
  ('ee000000-0000-0000-0000-0000000000e2','a2@x.com','{"username":"other"}');

-- ---- the shape of the three, on the card ----------------------------------
select t_ok((select aura_kind = 'resist' and aura_class = 'knight' and aura_pct = 20
               from public.cards where slug = 'dereo'),
            'KING DEREO takes a fifth off what Knights land on his side');
select t_ok((select aura_kind = 'bonus' and aura_class = 'mage' and aura_pct = 20
               from public.cards where slug = 'miah'),
            'QUEEN MIAH adds a fifth to what her side lands on Mages');
select t_ok((select aura_kind = 'resist_effects' and aura_class is null and aura_pct = 50
               from public.cards where slug = 'stelaris'),
            'KING STELARIS halves burn and poison, which is F2''s to spend');
select t_ok((select count(*) from public.cards where aura_kind is not null and not royal) = 0,
            'and nothing that is not a crown carries an aura at all');

-- An aura on a commoner is refused rather than ignored: a card that cannot be
-- right should not be storable, because a stored one is found by a player.
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
select t_raises($$update public.cards set aura_kind = 'resist', aura_class = 'mage',
                         aura_pct = 20 where slug = 'mako'$$,
                'only a Royal carries an aura', 'an aura on a Rogue is refused');
select t_raises($$update public.cards set aura_class = 'wizard' where slug = 'dereo'$$,
                'aura that names a class', 'and an aura against a class that does not exist');
select set_config('request.jwt.claims', '', false);

-- ---- and on the board -----------------------------------------------------
-- Both sides carry a crown, because a kingdom must. The host leads with the
-- pair -- Knights -- and the guest's Dereo is what makes them hit softer.
select set_config('app.uid','ee000000-0000-0000-0000-0000000000e1',false);
select public.set_deck(array['dione-grifo','dereo','mako','fey','eva']);
select set_config('app.uid','ee000000-0000-0000-0000-0000000000e2',false);
select public.set_deck(array['dereo','umiro','lumea','mako','eva']);

select t_match('ee000000-0000-0000-0000-0000000000e1',
               'ee000000-0000-0000-0000-0000000000e2') as m \gset
select set_config('app.uid','ee000000-0000-0000-0000-0000000000e1',false);
select t_trees(:'m','[]'::jsonb);
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'m','h1','role') = 'knight', 'the host leads with a Knight');
select t_ok(t_get(:'m','g1','role') = 'royal' and t_get(:'m','g1','auraKind') = 'resist',
            'and the guest''s crown is standing, with its aura on the board');

-- The blow is pinned so the fifth is arithmetic rather than a range: 50 flat,
-- 20% off, 40 landed.
select t_reset(:'m'); select t_place(:'m','h1',2,2); select t_place(:'m','g2',2,3);
select t_hp(:'m','g2',100); select t_dmg(:'m','h1',50);
select public.submit_attack(:'m','h1','g2');
select t_ok(t_get(:'m','g2','hp')::int = 60,
            'A KNIGHT LANDS 40 OF ITS 50 — the crown takes the fifth off');

-- NOT everything. A Rogue's blow is a Rogue's blow, whoever is watching.
select t_reset(:'m'); select t_place(:'m','h3',2,2); select t_place(:'m','g2',2,3);
select t_hp(:'m','g2',100); select t_dmg(:'m','h3',50);
select public.submit_attack(:'m','h3','g2');
select t_ok(t_get(:'m','g2','hp')::int = 50,
            'and NOT a Rogue''s — an aura that applied to everything would be a health bar');

-- NOR the other way round. The host's own crown does not protect the guest.
-- The turn is handed over first, then the board is rigged: end_turn clears
-- every unit's flags, so rigging before it would be rigging the wrong turn.
select set_config('app.uid','ee000000-0000-0000-0000-0000000000e1',false);
select public.end_turn(:'m');
select set_config('app.uid','ee000000-0000-0000-0000-0000000000e2',false);
select t_reset(:'m'); select t_place(:'m','g1',2,3); select t_place(:'m','h1',2,2);
select t_hp(:'m','h1',100); select t_dmg(:'m','g1',50);
select public.submit_attack(:'m','g1','h1');
select t_ok(t_get(:'m','h1','hp')::int = 50,
            'AND IT GUARDS ITS OWN SIDE ONLY — the crown is not a rule about Knights');

-- ---- the functions, on their own ------------------------------------------
-- The board above can only reach the one aura that is playable today. These
-- ask the other two directly, because building two thirds of a feature and
-- testing one third of it is how the other two arrive broken in F3.
create or replace function t_u(p_side text, p_role text, p_kind text,
                               p_class text, p_pct int)
returns jsonb language sql immutable as $$
  select jsonb_build_object('owner', p_side, 'role', p_role, 'hp', 100,
                            'royal', p_kind is not null,
                            'auraKind', p_kind, 'auraClass', p_class, 'auraPct', p_pct)
$$;
create or replace function t_board(variadic p jsonb[]) returns jsonb
language sql immutable as $$ select jsonb_build_object('units', to_jsonb(p)) $$;

select t_ok(public.cn_aura_bonus(
              t_board(t_u('host','royal','bonus','mage',20), t_u('host','rogue',null,null,null)),
              t_u('host','rogue',null,null,null), t_u('guest','mage',null,null,null)) = 0.20,
            'MIAH adds a fifth when her side swings at a Mage');
select t_ok(public.cn_aura_bonus(
              t_board(t_u('host','royal','bonus','mage',20)),
              t_u('host','rogue',null,null,null), t_u('guest','knight',null,null,null)) = 0,
            'and nothing at all when it swings at a Knight');
select t_ok(public.cn_aura_bonus(
              t_board(t_u('guest','royal','bonus','mage',20)),
              t_u('host','rogue',null,null,null), t_u('guest','mage',null,null,null)) = 0,
            'and nothing when the crown is on the other side');

select t_ok(public.cn_aura_resist(
              t_board(t_u('guest','royal','resist','knight',20)),
              t_u('host','knight',null,null,null), t_u('guest','mage',null,null,null)) = 0.20,
            'a resistance reads the SWINGER''s class and the RECEIVER''s side');
select t_ok(public.cn_aura_resist(
              t_board(t_u('guest','royal','resist','knight',20)),
              t_u('host','mage',null,null,null), t_u('guest','mage',null,null,null)) = 0,
            'so a Mage swinging into it is unaffected');

-- A crown that has fallen grants nothing. It can never happen in a match --
-- losing your royal ends it -- but the rule is written that way and a rule
-- that is never exercised is a rule nobody can rely on later.
select t_ok(public.cn_aura_resist(
              jsonb_build_object('units', jsonb_build_array(
                jsonb_build_object('owner','guest','role','royal','hp',0,'royal',true,
                                   'auraKind','resist','auraClass','knight','auraPct',20))),
              t_u('host','knight',null,null,null), t_u('guest','mage',null,null,null)) = 0,
            'AND A FALLEN CROWN GRANTS NOTHING');
