-- Local-only: plays a full match through the real RPCs and asserts the rules.
\set ON_ERROR_STOP on
\pset pager off

create or replace function t_ok(cond boolean, label text) returns void
language plpgsql as $$
begin
  if cond then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %', label; end if;
end $$;

-- Expect the next statement to raise, and to mention `frag`.
create or replace function t_raises(sql text, frag text, label text) returns void
language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if position(lower(frag) in lower(SQLERRM)) > 0 then
      raise notice 'PASS  % (blocked: %)', label, SQLERRM;
      return;
    else
      raise exception 'FAIL  % — wrong error: %', label, SQLERRM;
    end if;
  end;
  raise exception 'FAIL  % — was allowed but should not be', label;
end $$;

-- RLS blocks an UPDATE by making the rows invisible rather than by raising,
-- so "was refused" here means "changed nothing".
create or replace function t_norows(sql text, label text) returns void
language plpgsql as $$
declare n int;
begin
  execute sql;
  get diagnostics n = row_count;
  if n = 0 then raise notice 'PASS  % (0 rows changed)', label;
  else raise exception 'FAIL  % — % row(s) changed', label, n; end if;
end $$;

-- Deterministic roster: two identical cards, long range so the test can reach.
delete from public.matches;
delete from public.cards;
insert into public.cards (name, hp, attack, move, range, accent) values
  ('Alpha', 10, 4, 3, 6, '#7dd3fc'),
  ('Beta',  10, 4, 3, 6, '#f0abfc');

delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'alice@x.com', '{"username":"alice"}'),
  ('22222222-2222-2222-2222-222222222222', 'bob@x.com',   '{"username":"bob"}'),
  ('33333333-3333-3333-3333-333333333333', 'carol@x.com', '{"username":"carol"}');

select t_ok((select count(*) from public.profiles) = 3, 'signup trigger created 3 profiles');

-- ---- alice hosts --------------------------------------------------------
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select id as mid from public.create_match() \gset

select t_ok((select status from public.matches where id = :'mid') = 'waiting', 'new match is waiting');
select t_ok((select jsonb_array_length(state->'units') from public.matches where id=:'mid') = 4,
            'four units on the board');

-- alice cannot move before anyone joins
select t_raises(format('select public.submit_move(%L,''h1'',1,1)', :'mid'),
                'not running', 'no moves while the room is empty');

-- ---- bob joins ----------------------------------------------------------
select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);
select code as mcode from public.matches where id = :'mid' \gset
select public.join_match(:'mcode');

select t_ok((select status from public.matches where id=:'mid') = 'active', 'match went active on join');
select t_ok((select turn_deadline > now() from public.matches where id=:'mid'), 'turn clock started');
select t_ok((select state->>'turn' from public.matches where id=:'mid') = 'host', 'host acts first');

-- bob is guest; it is not his turn
select t_raises(format('select public.submit_move(%L,''g1'',5,1)', :'mid'),
                'not your turn', 'guest cannot act on the host turn');

-- ---- alice's turn -------------------------------------------------------
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);

select t_raises(format('select public.submit_move(%L,''g1'',5,1)', :'mid'),
                'not your unit', 'cannot move the opponent''s unit');
select t_raises(format('select public.submit_move(%L,''h1'',6,4)', :'mid'),
                'too far', 'move range is enforced');
select t_raises(format('select public.submit_move(%L,''h1'',9,9)', :'mid'),
                'off the board', 'board bounds are enforced');
select t_raises(format('select public.submit_move(%L,''h1'',0,3)', :'mid'),
                'occupied', 'cannot stack two units on a tile');

select public.submit_move(:'mid', 'h1', 2, 1);
select t_ok((select (u->>'x')::int from public.matches m,
             jsonb_array_elements(m.state->'units') u
             where m.id=:'mid' and u->>'id'='h1') = 2, 'move applied');

select t_raises(format('select public.submit_move(%L,''h1'',3,1)', :'mid'),
                'already moved', 'one move per unit per turn');

-- attack across the board (range 6, distance from (2,1) to (6,1) is 4)
select public.submit_attack(:'mid', 'h1', 'g1');
select t_ok((select (u->>'hp')::int from public.matches m,
             jsonb_array_elements(m.state->'units') u
             where m.id=:'mid' and u->>'id'='g1') = 6, 'damage applied');
select t_raises(format('select public.submit_attack(%L,''h1'',''g1'')', :'mid'),
                'already attacked', 'one attack per unit per turn');
select t_raises(format('select public.submit_attack(%L,''h2'',''h1'')', :'mid'),
                'friendly fire', 'no friendly fire');

select public.end_turn(:'mid');
select t_ok((select state->>'turn' from public.matches where id=:'mid') = 'guest', 'turn passed to guest');
select t_ok((select bool_and(not (u->>'moved')::boolean) from public.matches m,
             jsonb_array_elements(m.state->'units') u where m.id=:'mid'),
            'unit actions reset on turn change');

-- ---- the 30-second clock -----------------------------------------------
-- carol is only a spectator, and force_timeout is the mechanism the clients
-- use to expire a turn. It must do nothing while time remains...
select set_config('app.uid', '33333333-3333-3333-3333-333333333333', false);
select public.force_timeout(:'mid');
select t_ok((select state->>'turn' from public.matches where id=:'mid') = 'guest',
            'force_timeout does nothing before the deadline');

select t_raises(format('select public.submit_move(%L,''g1'',5,1)', :'mid'),
                'spectating', 'spectators cannot move pieces');
select t_raises(format('select public.end_turn(%L)', :'mid'),
                'spectating', 'spectators cannot end a turn');

-- ...and must expire it once the deadline has genuinely passed.
update public.matches set turn_deadline = now() - interval '5 seconds' where id = :'mid';
select public.force_timeout(:'mid');
select t_ok((select state->>'turn' from public.matches where id=:'mid') = 'host',
            'force_timeout passes the turn once time is up');
select t_ok((select state->'log'->-1->>'text' from public.matches where id=:'mid') like 'Turn 3%',
            'timeout advanced the turn counter');

-- a player whose clock expired cannot sneak a move in
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
update public.matches set turn_deadline = now() - interval '10 seconds' where id = :'mid';
select t_raises(format('select public.submit_move(%L,''h2'',1,3)', :'mid'),
                'time ran out', 'expired turns reject moves');
update public.matches set turn_deadline = now() + interval '30 seconds' where id = :'mid';

-- ---- win condition ------------------------------------------------------
update public.matches
   set state = jsonb_set(state, '{units}', (
         select jsonb_agg(case when u->>'owner'='guest'
                               then jsonb_set(u,'{hp}','1'::jsonb) else u end)
         from jsonb_array_elements(state->'units') u))
 where id = :'mid';

select public.submit_attack(:'mid', 'h1', 'g1');
select public.submit_attack(:'mid', 'h2', 'g2');

select t_ok((select status from public.matches where id=:'mid') = 'finished', 'match finished');
select t_ok((select winner from public.matches where id=:'mid') = 'host', 'host recorded as winner');
select t_ok((select jsonb_array_length(state->'units') from public.matches where id=:'mid') = 2,
            'destroyed units removed from the board');

-- ---- privilege checks ---------------------------------------------------
-- Supabase grants table privileges to these roles and relies on RLS to
-- constrain them; mirror that so the policy checks below are the real test.
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

set role authenticated;
select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);

select t_raises(format('select public.advance_turn(%L, null)', :'mid'),
                'permission denied', 'advance_turn is not callable by players');
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
\echo '--- all assertions passed ---'
