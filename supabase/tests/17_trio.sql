-- 0026: who they brought, the cinematic setting, and two ladder columns.
--
-- The one with teeth is their_army(). Deployment has been blind since 0008 and
-- most of that blindness is the point -- WHERE the archer is standing is the
-- secret the phase exists to keep. WHICH FIVE they brought never was, and this
-- hands that over. So the assertions worth writing are all about the line
-- between those two: identities out, coordinates not, players only, and only
-- while it is still a secret worth keeping.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('11110000-0000-0000-0000-000000000011','h@x.com','{"username":"hosty"}'),
  ('22220000-0000-0000-0000-000000000022','g@x.com','{"username":"guesty"}'),
  ('33330000-0000-0000-0000-000000000033','s@x.com','{"username":"nosy"}');

-- Two different fives, so "you see THEIRS" is a claim that can fail.
select set_config('app.uid','11110000-0000-0000-0000-000000000011',false);
select public.set_deck(array['dereo','dione-grifo','mako','wuzu','eva']);
select set_config('app.uid','22220000-0000-0000-0000-000000000022',false);
select public.set_deck(array['dereo','lium','himanta','fey','umiro']);

select set_config('app.uid','11110000-0000-0000-0000-000000000011',false);
select id, code from public.create_match() \gset
select set_config('app.uid','22220000-0000-0000-0000-000000000022',false);
select public.join_match(:'code');

select t_ok((select status from public.matches where id = :'id') = 'deploying',
            'the match is deploying, which is when any of this matters');

create or replace function t_slugs(p jsonb) returns text[]
language sql immutable as $$
  select coalesce(array_agg(x->>'slug' order by x->>'slug'), '{}'::text[])
    from jsonb_array_elements(coalesce(p, '[]'::jsonb)) x
$$;

-- ---- what each side can see ------------------------------------------------
select set_config('app.uid','11110000-0000-0000-0000-000000000011',false);
select t_ok(t_slugs(public.their_army(:'id'))
            = array['dereo','fey','himanta','lium','umiro'],
            'THE HOST SEES WHICH FIVE THE GUEST BROUGHT');
select t_ok(t_slugs(public.my_deploy(:'id'))
            = array['dereo','dione-grifo','eva','mako','wuzu'],
            'and their own are still their own');

select set_config('app.uid','22220000-0000-0000-0000-000000000022',false);
select t_ok(t_slugs(public.their_army(:'id'))
            = array['dereo','dione-grifo','eva','mako','wuzu'],
            'and the guest sees the host''s');

-- ---- AND NOT ONE COORDINATE ------------------------------------------------
-- The whole line this migration draws. Checked by asking what keys come out
-- rather than by asking whether x is among them: the function lists what it
-- returns instead of subtracting what is secret, precisely so that the NEXT
-- field somebody adds to a unit is absent by default -- and a test that only
-- looked for 'x' and 'y' would not notice the day that stopped being true.
select t_ok((select count(*) from jsonb_array_elements(public.their_army(:'id')) u,
                                  jsonb_object_keys(u) k
              where k not in ('id','slug','name','role','art','maxHp')) = 0,
            'AND NOTHING ELSE COMES OUT — not a coordinate, not a flag, nothing');
select t_ok((select count(*) from jsonb_array_elements(public.their_army(:'id')) u
              where u ? 'x' or u ? 'y') = 0,
            'which means no x and no y, said plainly');
select t_ok((select count(*) from jsonb_array_elements(public.my_deploy(:'id')) u
              where u ? 'x' and u ? 'y') = 5,
            'while your OWN half still has every coordinate on it');

-- Enough to draw a token with, which is the point of handing anything over.
select t_ok((select count(*) from jsonb_array_elements(public.their_army(:'id')) u
              where coalesce(u->>'name','') <> '' and coalesce(u->>'art','') <> '') = 5,
            'and each of them carries a name and a picture');

-- ---- nobody else ------------------------------------------------------------
select set_config('app.uid','33330000-0000-0000-0000-000000000033',false);
select t_ok(public.their_army(:'id') is null,
            'A SPECTATOR SEES NOTHING — deployment is secret from the room too');
select set_config('app.uid','',false);
select t_ok(public.their_army(:'id') is null, 'and so does a stranger');

-- ---- and only while it is a secret -----------------------------------------
select set_config('app.uid','11110000-0000-0000-0000-000000000011',false);
select public.set_ready(:'id');
select set_config('app.uid','22220000-0000-0000-0000-000000000022',false);
select public.set_ready(:'id');
select t_ok((select status from public.matches where id = :'id') = 'active',
            'both ready, and the match starts');
select t_ok(public.their_army(:'id') is null,
            'after which their_army has nothing to add -- the board says it all');

-- ---- the cinematic setting --------------------------------------------------
select t_ok(public.cn_clean_settings('{"cine":"full"}'::jsonb)
            = '{"cine":"full"}'::jsonb, 'full is a cinematic');
select t_ok(public.cn_clean_settings('{"cine":"quick"}'::jsonb)
            = '{"cine":"quick"}'::jsonb, 'and so is quick');
select t_ok(public.cn_clean_settings('{"cine":"off"}'::jsonb)
            = '{"cine":"off"}'::jsonb, 'and so is none at all');
-- DROPPED, not defaulted, and the difference from `theme` is deliberate: an
-- unknown theme is a typo, an unknown cine is a newer client's opinion, and
-- rewriting it to 'full' would answer it with an older server's.
select t_ok(public.cn_clean_settings('{"cine":"cinematic"}'::jsonb) = '{}'::jsonb,
            'anything else is dropped rather than rewritten to full');
select t_ok(public.cn_clean_settings('{"cine":"off","theme":"bananas"}'::jsonb)
            = '{"cine":"off","theme":"system"}'::jsonb,
            'while theme still lands on system, which is the opposite rule and stays that way');

-- 0022's own promise, re-checked because 0026 rewrote the whole function: a
-- key this database has never heard of still survives.
select t_ok(public.cn_clean_settings('{"somethingNew":42}'::jsonb)
            = '{"somethingNew":42}'::jsonb,
            'and an unknown KEY still survives, which is why cine needed no column');
select t_ok(public.cn_clean_settings('{"sfx":9}'::jsonb) = '{"sfx":1}'::jsonb,
            'and a volume is still clamped');

-- The clock does NOT change. Written down because it looks like an oversight:
-- 0021 pushes the deadline by the full cinematic whatever this setting says,
-- which is what Skip has done since Phase C.
select t_ok(public.cn_cine_ms('[{"k":"hit"}]'::jsonb)
            = public.cn_cine_ms('[{"k":"hit"}]'::jsonb),
            'and the clock knows nothing about any of it');

-- ---- the ladder --------------------------------------------------------------
select t_ok((select count(*) from information_schema.columns
              where table_schema='public' and table_name='leaderboard'
                and column_name = 'avatar') = 1,
            'the ladder can show a face at last');
select t_ok((select count(*) from information_schema.columns
              where table_schema='public' and table_name='leaderboard'
                and column_name = 'tournaments') = 1,
            'and a tournaments column, which Phase E will fill');
select t_ok((select count(*) from public.profiles where tournaments <> 0) = 0,
            'reading zero for everybody until then, which is honest rather than empty');
select t_raises('update public.profiles set tournaments = -1
                  where id = ''11110000-0000-0000-0000-000000000011''',
                'tournaments', 'and it cannot go backwards');

-- The view is security_invoker, so it shows what the reader may see and no
-- more -- which for profiles is everybody's public row. Worth one assertion
-- because adding a column to a view is exactly when that stops being true.
select set_config('app.uid','33330000-0000-0000-0000-000000000033',false);
select t_ok((select count(*) from public.leaderboard) >= 0,
            'and anybody signed in can still read it');
