-- 0029: an UPDATE on `matches` has to carry the board with it.
--
-- The white screen was not a client bug wearing a server hat. `matches.state`
-- is `jsonb not null`; the database never held a match without a board. But an
-- UPDATE that does not ASSIGN a toasted column leaves its pointer alone, and
-- logical replication then has nothing to send for it -- so the row that came
-- down the websocket had no state on it, and the screen that read it fell over.
-- Measured in the WAL with test_decoding, which is what turned this from a
-- theory into a cause:
--
--   update m set turn_deadline = ... where id = 1;
--     -> state[jsonb]:unchanged-toast-datum
--   update m set turn_deadline = ..., state = v where id = 1;
--     -> state[jsonb]:'[{"id": "d77b5ae2...
--
-- A test file cannot run a replication slot, so what it CAN do is hold the
-- rule: every function that updates `matches` assigns `state` in the same
-- statement, and the handful that deliberately do not are named here by name.
-- A rule with no test is a rule with a date on it, and this one is invisible
-- -- nothing fails, nothing errors, a column is quietly absent three machines
-- away -- which is exactly the kind that needs writing down.
\set ON_ERROR_STOP on
\pset pager off

-- Every UPDATE on matches in the whole schema, and whether its SET list says
-- `state`. Crude on purpose: it reads the source text rather than parsing SQL,
-- because the thing being guarded is a habit and the guard has to be legible
-- to the next person who writes one of these.
create or replace function t_stateless() returns text[]
language sql stable as $$
  select coalesce(array_agg(distinct p.proname order by p.proname), '{}'::text[])
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace,
         lateral regexp_matches(p.prosrc,
           'update\s+(?:public\.)?matches\s+set([\s\S]{0,200})', 'g') as m(g)
   where n.nspname = 'public'
     -- The rigging is exempt, and says so in _helpers.sql: t_set, t_place and
     -- friends write the board directly BECAUSE no client can, which is the
     -- only way a test gets a known position. They are not on any replication
     -- path anybody watches.
     and p.proname not like 't\_%'
     and m.g[1] !~ '\mstate\M'
$$;

-- ---- the two that mattered ---------------------------------------------------
-- submit_attack is the reported bug: 0021 pushes the turn deadline in a second
-- statement, and that statement touched one column. Every attack, every match,
-- every device.
select t_ok(not ('submit_attack' = any(t_stateless())),
            'THE ATTACK PATH SENDS THE BOARD — which is the white screen, from the server''s side');
-- deploy_unit's last statement is a pure touch, whose entire job is to make
-- realtime fire. A touch that fires and sends half a row is worse than no
-- touch at all.
select t_ok(not ('deploy_unit' = any(t_stateless())),
            'and so does the deployment touch, whose only purpose was ever to make realtime fire');

-- And the fix is the assignment, not a comment about one.
select t_ok((select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'submit_attack') ~ 'state\s*=\s*m\.state',
            'by assigning state from a variable, which is what writes a fresh datum');

-- ---- nothing else that a player touches mid-match -----------------------------
-- The allow-list, and the whole point of the file. These fire once, at the end
-- of a match, on a screen with no board on it, and the client refetches when a
-- row arrives without a state -- so they are acceptable, not invisible. If this
-- array grows, somebody has added a half-row to a path nobody has thought
-- about, and they will find out here rather than from a white screen.
select t_ok(t_stateless() <@ array['decline_rematch', 'request_rematch'],
            'AND NOTHING ELSE UPDATES matches WITHOUT THE BOARD — only the rematch pair, on purpose');

-- The rules themselves still work. A whole attack through the real function,
-- because a splice is exactly where a migration quietly changes behaviour.
delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('cc000000-0000-0000-0000-0000000000c1','x1@x.com','{"username":"one"}'),
  ('cc000000-0000-0000-0000-0000000000c2','x2@x.com','{"username":"two"}');

select set_config('app.uid','cc000000-0000-0000-0000-0000000000c1',false);
select id, code from public.create_match() \gset
select set_config('app.uid','cc000000-0000-0000-0000-0000000000c2',false);
select public.join_match(:'code');

-- Deployment still moves a unit, and still says so.
select set_config('app.uid','cc000000-0000-0000-0000-0000000000c1',false);
select (jsonb_array_elements(public.my_deploy(:'id'))->>'id') as uid from public.matches
 where id = :'id' limit 1 \gset
select updated_at as before_touch from public.matches where id = :'id' \gset
select t_ok(jsonb_array_length(public.deploy_unit(:'id', :'uid', 2, 0)) = public.deck_size(),
            'deploy_unit still returns your whole half after the splice');
select t_ok((select updated_at from public.matches where id = :'id') > :'before_touch',
            'and still touches the row, so the other client still hears about it');
select t_ok((select jsonb_array_length(state->'units') from public.matches where id = :'id') = 0,
            'and still does not put anybody''s army in the shared row');

select public.set_ready(:'id');
select set_config('app.uid','cc000000-0000-0000-0000-0000000000c2',false);
select public.set_ready(:'id');
select t_ok((select status from public.matches where id = :'id') = 'active',
            'both ready and the match runs');

-- An attack, through submit_attack itself, with the clock checked on both
-- sides of it: 0021's whole reason for that second statement is that the
-- deadline moves by the length of the fight, and a splice that lost it would
-- hand the cinematic back as thinking time.
select t_set(:'id', (select u->>'id' from public.matches m,
                       jsonb_array_elements(m.state->'units') u
                      where m.id = :'id' and u->>'owner' = 'host' limit 1), 'x', '2'::jsonb);
select set_config('app.uid','cc000000-0000-0000-0000-0000000000c1',false);
select u->>'id' as atk from public.matches m, jsonb_array_elements(m.state->'units') u
 where m.id = :'id' and u->>'owner' = 'host' limit 1 \gset
select u->>'id' as tgt from public.matches m, jsonb_array_elements(m.state->'units') u
 where m.id = :'id' and u->>'owner' = 'guest' limit 1 \gset
select t_place(:'id', :'atk', 2, 2);
select t_place(:'id', :'tgt', 2, 3);
select turn_deadline as dl0 from public.matches where id = :'id' \gset
select public.submit_attack(:'id', :'atk', :'tgt');
select t_ok((select state->'fx' is not null from public.matches where id = :'id'),
            'AN ATTACK STILL LANDS, and still leaves an fx behind for the cinematic');
select t_ok((select turn_deadline from public.matches where id = :'id') > :'dl0',
            'and the clock is still pushed by the length of the fight — 0021 survived the splice');
select t_ok((select jsonb_array_length(state->'units') from public.matches where id = :'id')
            = public.deck_size() * 2,
            'and the board that came back is a whole board, which is the entire point');
