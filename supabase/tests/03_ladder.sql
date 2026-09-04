-- Local-only: proves the ladder cannot be farmed and that floors hold.
\set ON_ERROR_STOP on

delete from public.match_results;
delete from public.matches;
delete from auth.users;
update public.app_settings set season = 1 where id;
insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'a@x.com', '{"username":"alice"}'),
  ('22222222-2222-2222-2222-222222222222', 'b@x.com', '{"username":"bob"}');

-- helper: alice hosts, bob joins, alice resigns  => bob wins
create or replace function t_play(p_winner text) returns void
language plpgsql as $$
declare mid uuid; c text;
begin
  perform set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
  select id, code into mid, c from public.create_match();
  perform set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);
  perform public.join_match(c);
  -- the loser resigns
  if p_winner = 'bob' then
    perform set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
  else
    perform set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);
  end if;
  perform public.resign_match(mid);
end $$;

select t_ok((select lp from public.profiles where username='alice') = 0, 'everyone starts at 0 LP');

-- an even first game: 1000 vs 1000 => expected .5 => swing 14
select t_play('bob');
select t_ok((select lp from public.profiles where username='bob') = 14, 'winner gains 14 from an even match');
select t_ok((select lp from public.profiles where username='alice') = 0, 'loser cannot go below zero');
select t_ok((select wins from public.profiles where username='bob') = 1, 'the win is recorded');
select t_ok((select streak from public.profiles where username='alice') = -1, 'and the losing streak');
select t_ok((select count(*) from public.match_results) = 1, 'the result outlives the room');
select t_ok((select reason from public.match_results) = 'resign', 'and remembers how it ended');

-- THE ONE THAT MATTERS: alternating wins must not enrich both players
select t_play('alice');
select t_play('bob');
select t_play('alice');
select t_play('bob');
select t_ok((select sum(lp) from public.profiles) <= 30,
            'alternating wins do not inflate the ladder');
select t_ok((select lp from public.profiles where username='alice')
          + (select lp from public.profiles where username='bob')
          = (select sum(winner_lp + loser_lp) from public.match_results),
            'LP is conserved: every point won came from somewhere');

-- Beating someone far below you must be worth almost nothing, and losing to
-- them must hurt. Both LP values are set explicitly so the drop is actually
-- measurable -- left to drift, bob floors at 0 and the test proves nothing.
update public.player_rating set mmr = 1600 where user_id = '22222222-2222-2222-2222-222222222222';
update public.player_rating set mmr =  900 where user_id = '11111111-1111-1111-1111-111111111111';
update public.profiles set lp = 500, floor_lp = 300;

select t_play('bob');
select t_ok((select lp from public.profiles where username='bob') - 500 <= 6,
            'crushing a weaker player is worth almost nothing');

update public.player_rating set mmr = 1600 where user_id = '22222222-2222-2222-2222-222222222222';
update public.player_rating set mmr =  900 where user_id = '11111111-1111-1111-1111-111111111111';
update public.profiles set lp = 500, floor_lp = 300;

select t_play('alice');
select t_ok(500 - (select lp from public.profiles where username='bob') >= 20,
            'losing to a weaker player hurts');
select t_ok((select lp from public.profiles where username='alice') - 500 >= 20,
            'and beating someone far above you pays');

-- Tier floors. alice sits 5 points above the Gold floor and is about to lose
-- 14, so without the floor she would fall to 591 and out of the tier.
update public.profiles set lp = 605, floor_lp = 600;
update public.player_rating set mmr = 1000;
select t_play('bob');
select t_ok((select lp from public.profiles where username='alice') = 600,
            'a tier floor stops you dropping out of your tier');
select t_ok((select loser_lp from public.match_results order by id desc limit 1) = -5,
            'and the result records what was actually lost, not the raw swing');
select t_ok(public.tier_of(600) = 'Gold' and public.tier_of(599) = 'Silver', 'tiers land where they should');

-- rematch
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select id as rm from public.create_match() \gset
select code as rc from public.matches where id = :'rm' \gset
select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);
select public.join_match(:'rc');
select public.resign_match(:'rm');

select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select t_ok(public.request_rematch(:'rm') is null, 'one player asking is not enough');
select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);
select public.request_rematch(:'rm') as newid \gset
select t_ok(:'newid' is not null, 'both asking creates the rematch');
select t_ok((select next_match_id from public.matches where id=:'rm')::text = :'newid',
            'the old room points at the new one so both clients find it');
select t_ok((select host_id from public.matches where id=:'newid'::uuid)
            = (select guest_id from public.matches where id=:'rm'),
            'sides swap, so nobody keeps the first move twice');
select t_ok((select count(*) from public.match_presence where match_id=:'newid'::uuid) = 2,
            'both players are present in the rematch');

-- The hidden rating must stay hidden. Mirror Supabase's default grants so
-- what is being tested is the RLS policy, not a missing GRANT.
grant usage on schema public to authenticated;
grant select on public.player_rating to authenticated;
set role authenticated;
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select t_ok((select count(*) from public.player_rating) = 1,
            'you can see your own rating and nobody elses');
reset role;

\echo '--- ladder assertions passed ---'
