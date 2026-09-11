-- 0021: the turn clock waits for the cinematic.
--
-- The rule is one sentence -- an attack pushes the deadline by exactly as long
-- as the fight takes to watch -- and almost everything that can go wrong with
-- it is a boundary rather than the sentence itself. So most of this file is
-- boundaries: the fight that ends the match (no clock left to push), the bot
-- (no screen to watch), the next turn (the extension must not compound), and
-- the cap.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaa1111-0000-0000-0000-00000000001a','a1@x.com','{"username":"ana"}'),
  ('bbbb1111-0000-0000-0000-00000000001b','b1@x.com','{"username":"bo"}');

create or replace function t_deadline(p_m uuid) returns timestamptz
language sql stable as $$ select turn_deadline from public.matches where id = p_m $$;
-- Milliseconds between two deadlines, rounded -- interval arithmetic in
-- Postgres is exact, but the assertion reads better as a number.
create or replace function t_gap(a timestamptz, b timestamptz) returns int
language sql immutable as $$ select round(extract(epoch from (a - b)) * 1000)::int $$;

-- ---- the budget, before any board ------------------------------------------
select t_ok(public.cn_cine_ms('[]'::jsonb) = 1600,
            'an empty exchange is still the lead-in and the hold');
select t_ok(public.cn_cine_ms(null) = 1600,
            'and so is a match from before 0020, which has no swings at all');
select t_ok(public.cn_cine_ms('"nonsense"'::jsonb) = 1600,
            'anything that is not a list is treated as none');
select t_ok(public.cn_cine_ms('[{"k":"hit"},{"k":"hit"}]'::jsonb) = 1600 + 1400,
            'a plain trade is two blows on top of the frame');
select t_ok(public.cn_cine_ms('[{"k":"parry"},{"k":"parry"}]'::jsonb) = 1600 + 1200,
            'a parry is shorter than a blow -- there is no health bar to drain');
select t_ok(public.cn_cine_ms('[{"k":"hit"},{"k":"down"}]'::jsonb) = 1600 + 1500,
            'and a falling is the longest single beat');
select t_ok(public.cn_cine_ms('[{"k":"who knows"}]'::jsonb) = 1600,
            'a beat the client cannot draw buys no time for it');
select t_ok(public.cn_cine_ms(
              (select jsonb_agg(jsonb_build_object('k','down')) from generate_series(1,40)))
            = 12000,
            'forty of them is capped at twelve seconds');
-- The cap has to be above anything the game can actually produce today, or it
-- would be silently shortening real fights.
select t_ok(public.cn_cine_ms(
              (select jsonb_agg(jsonb_build_object('k','parry'))
                 from generate_series(1, public.cn_parry_cap()))) < 12000,
            'and a full eight-parry chain is comfortably under it');

select t_match('aaaa1111-0000-0000-0000-00000000001a',
               'bbbb1111-0000-0000-0000-00000000001b') as m \gset

create or replace function t_duel3(p_m uuid) returns void language sql as $$
  select t_reset(p_m),
         t_place(p_m,'h1',2,2), t_place(p_m,'g3',2,3),
         t_full(p_m,'h1'), t_full(p_m,'g3'),
         t_dmg(p_m,'h1',40), t_dmg(p_m,'g3',40),
         t_set(p_m,'h1','rmin','1'::jsonb), t_set(p_m,'h1','rmax','1'::jsonb),
         t_set(p_m,'h1','crmin','1'::jsonb), t_set(p_m,'h1','crmax','1'::jsonb),
         t_set(p_m,'g3','rmin','1'::jsonb), t_set(p_m,'g3','rmax','1'::jsonb),
         t_set(p_m,'g3','crmin','1'::jsonb), t_set(p_m,'g3','crmax','1'::jsonb),
         t_hp(p_m,'h1',110), t_hp(p_m,'g3',110), t_set(p_m,'g3','maxHp','110'::jsonb),
         t_set(p_m,'h1','parryPct','5'::jsonb), t_set(p_m,'g3','parryPct','5'::jsonb),
         t_set(p_m,'h1','critPct','5'::jsonb),  t_set(p_m,'g3','critPct','5'::jsonb),
         t_set(p_m,'h1','parries','false'::jsonb), t_set(p_m,'g3','parries','false'::jsonb),
         t_set(p_m,'h1','parryAll','false'::jsonb), t_set(p_m,'g3','parryAll','false'::jsonb),
         t_set(p_m,'h1','burned','false'::jsonb), t_set(p_m,'g3','burned','false'::jsonb);
$$;

set cn.force_parry = 'never'; set cn.force_crit = 'never';
select set_config('app.uid','aaaa1111-0000-0000-0000-00000000001a',false);

-- ---- an ordinary trade buys exactly its own length --------------------------
select t_duel3(:'m');
select t_deadline(:'m') as before \gset
select public.submit_attack(:'m','h1','g3');
select t_ok(t_gap(t_deadline(:'m'), :'before'::timestamptz)
            = public.cn_cine_ms(t_sw(:'m')),
            'the deadline is pushed by exactly the cinematic''s length');
select t_ok(t_gap(t_deadline(:'m'), :'before'::timestamptz) = 1600 + 1400,
            'which for a plain trade is the frame plus two blows');

-- ---- a longer fight buys more, and it is the fight that decides -------------
set cn.force_parry = 'always';
select t_duel3(:'m');
select t_deadline(:'m') as before2 \gset
select public.submit_attack(:'m','h1','g3');
select t_ok(t_gap(t_deadline(:'m'), :'before2'::timestamptz)
            = public.cn_cine_ms(t_sw(:'m')),
            'an eight-parry chain buys its own length too');
select t_ok(t_gap(t_deadline(:'m'), :'before2'::timestamptz) > 1600 + 1400,
            'and it is more than a plain trade got');
set cn.force_parry = 'never';

-- ---- moving buys nothing ----------------------------------------------------
-- Only an exchange has anything to watch. A move that quietly extended the
-- clock would be a way to buy thinking time by shuffling a unit back and
-- forth, which is exactly the abuse this design is meant to have no door for.
select t_duel3(:'m');
select t_deadline(:'m') as before3 \gset
select public.submit_move(:'m','h1',3,2);
select t_ok(t_deadline(:'m') = :'before3'::timestamptz,
            'a move does not touch the clock');
select t_duel3(:'m');
select t_deadline(:'m') as before4 \gset
select public.submit_defend(:'m','h1');
select t_ok(t_deadline(:'m') = :'before4'::timestamptz,
            'and neither does raising a guard');

-- ---- the extension does not compound into the next turn ---------------------
select t_duel3(:'m');
select public.submit_attack(:'m','h1','g3');
select public.end_turn(:'m');
select t_ok(t_gap(t_deadline(:'m'), now()) between 29000 and 31000,
            'a new turn is thirty seconds again, not thirty plus what was bought');

-- ---- the winning blow has no clock to push ----------------------------------
-- The section above ended the turn, which handed it to the guest. Hand it back
-- rather than playing on as them: this file is about the attacker's clock, and
-- t_reset deliberately does not touch whose turn it is.
update public.matches
   set state = jsonb_set(state, '{turn}', '"host"'::jsonb),
       turn_deadline = now() + interval '60 seconds'
 where id = :'m';
select t_duel3(:'m');
select set_config('app.uid','aaaa1111-0000-0000-0000-00000000001a',false);
select t_place(:'m','g3',5,5);
select t_place(:'m','g4',2,3); select t_hp(:'m','g4',10); select t_dmg(:'m','g4',5);
select t_set(:'m','g4','crmin','1'::jsonb); select t_set(:'m','g4','crmax','1'::jsonb);
-- g4 has to be the guest's ONLY royal, not an extra one. A kingdom holds
-- exactly one crown (0018), and cn_attack ends the match when the side that
-- lost one has none left standing -- so simply flagging g4 royal leaves the
-- real crown alive, the match running, and this section testing nothing.
update public.matches set state = jsonb_set(state, '{units}', (
  select jsonb_agg(case when u->>'owner' = 'guest'
                        then jsonb_set(u, '{royal}', to_jsonb(u->>'id' = 'g4'))
                        else u end)
    from jsonb_array_elements(state->'units') u)) where id = :'m';
select public.submit_attack(:'m','h1','g4');
select t_ok((select status from public.matches where id = :'m') = 'finished',
            'the crown falls and the match is over');
select t_ok(t_deadline(:'m') is null,
            'and a match that just ended has no deadline to push');

reset cn.force_parry; reset cn.force_crit;
