-- 0022: settings follow the account.
--
-- Two halves. The cleaner, which is where all the judgement is, and the door,
-- which is where the merge behaviour and the authorisation are. The cleaner is
-- pure so most of this file is table-driven and needs no board at all.
--
-- The claim worth defending is the odd-looking one: KNOWN keys are validated
-- and UNKNOWN keys survive. Each half has a failure it prevents. Drop unknown
-- keys and a client one deploy ahead of the database loses every new setting
-- silently -- which is a normal state here, because the site deploys instantly
-- and migrations are pasted in by hand. Keep everything unvalidated and a
-- volume of 40 or a theme of 'bananas' comes back as a broken screen on every
-- device rather than on the one that wrote it.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('a2220000-0000-0000-0000-00000000002a','s1@x.com','{"username":"sett"}'),
  ('b2220000-0000-0000-0000-00000000002b','s2@x.com','{"username":"tings"}');

create or replace function t_settings(p_id uuid) returns jsonb
language sql stable as $$ select settings from public.profiles where id = p_id $$;

-- ---- the cleaner ------------------------------------------------------------
select t_ok(public.cn_clean_settings('{}'::jsonb) = '{}'::jsonb,
            'nothing in, nothing out');
select t_ok(public.cn_clean_settings(null) = '{}'::jsonb,
            'and null is nothing too');
select t_ok(public.cn_clean_settings('"nope"'::jsonb) = '{}'::jsonb,
            'a string is not a settings object');
select t_ok(public.cn_clean_settings('[1,2]'::jsonb) = '{}'::jsonb,
            'and neither is a list');

-- volumes
select t_ok(public.cn_clean_settings('{"sfx":0.5}'::jsonb) = '{"sfx":0.5}'::jsonb,
            'a volume in range is left alone');
select t_ok(public.cn_clean_settings('{"sfx":5}'::jsonb) = '{"sfx":1}'::jsonb,
            'a volume above one is brought down to one');
select t_ok(public.cn_clean_settings('{"music":-3}'::jsonb) = '{"music":0}'::jsonb,
            'and one below nothing is brought up to nothing');
-- Clamped rather than refused, on purpose: a refusal would lose every OTHER
-- setting travelling in the same patch.
select t_ok(public.cn_clean_settings('{"sfx":9,"theme":"dark"}'::jsonb)
            = '{"sfx":1,"theme":"dark"}'::jsonb,
            'a bad volume does not take the good theme down with it');
select t_ok(public.cn_clean_settings('{"sfx":"loud"}'::jsonb) = '{}'::jsonb,
            'a volume that is not a number is dropped rather than guessed at');

-- the theme, and the language that comes after it
select t_ok(public.cn_clean_settings('{"theme":"dark"}'::jsonb) = '{"theme":"dark"}'::jsonb,
            'dark is a theme');
select t_ok(public.cn_clean_settings('{"theme":"light"}'::jsonb) = '{"theme":"light"}'::jsonb,
            'so is light');
select t_ok(public.cn_clean_settings('{"theme":"system"}'::jsonb) = '{"theme":"system"}'::jsonb,
            'and so is asking the operating system');
select t_ok(public.cn_clean_settings('{"theme":"bananas"}'::jsonb) = '{"theme":"system"}'::jsonb,
            'anything else lands on system, which is the only sensible default');
select t_ok(public.cn_clean_settings('{"lang":"es"}'::jsonb) = '{"lang":"es"}'::jsonb,
            'Spanish is a language');
select t_ok(public.cn_clean_settings('{"lang":"fr"}'::jsonb) = '{}'::jsonb,
            'French is not one yet, and is dropped rather than defaulted -- a
             language nobody has translated would be a half-English screen');

-- reduce motion
select t_ok(public.cn_clean_settings('{"reduceMotion":true}'::jsonb)
            = '{"reduceMotion":true}'::jsonb, 'a switch that is a boolean is kept');
select t_ok(public.cn_clean_settings('{"reduceMotion":"yes"}'::jsonb) = '{}'::jsonb,
            'and one that is a string is not');

-- the part that is easy to get backwards
select t_ok(public.cn_clean_settings('{"somethingNew":42}'::jsonb)
            = '{"somethingNew":42}'::jsonb,
            'a key this migration has never heard of SURVIVES');
select t_ok(public.cn_clean_settings('{"sfx":9,"somethingNew":{"a":1}}'::jsonb)
            = '{"sfx":1,"somethingNew":{"a":1}}'::jsonb,
            'even when it is travelling beside one that had to be fixed');

-- and the size cap
select t_ok(public.cn_clean_settings(
              jsonb_build_object('big', repeat('x', 5000))) = '{}'::jsonb,
            'a novel in the settings column is refused outright');
select t_ok(public.cn_clean_settings(
              jsonb_build_object('ok', repeat('x', 100))) <> '{}'::jsonb,
            'while something merely long is fine');

-- ---- the door ---------------------------------------------------------------
select set_config('app.uid','a2220000-0000-0000-0000-00000000002a',false);

select t_ok(t_settings('a2220000-0000-0000-0000-00000000002a') = '{}'::jsonb,
            'a fresh profile has no settings');

select public.set_settings('{"sfx":0.8}'::jsonb);
select t_ok(t_settings('a2220000-0000-0000-0000-00000000002a') = '{"sfx":0.8}'::jsonb,
            'setting one writes one');

-- A PATCH. Two tabs on two screens would otherwise take turns wiping each
-- other, and settings are exactly the thing somebody has open twice.
select public.set_settings('{"theme":"dark"}'::jsonb);
select t_ok(t_settings('a2220000-0000-0000-0000-00000000002a')
            = '{"sfx":0.8,"theme":"dark"}'::jsonb,
            'and setting another KEEPS the first');
select public.set_settings('{"sfx":0.2}'::jsonb);
select t_ok(t_settings('a2220000-0000-0000-0000-00000000002a')
            = '{"sfx":0.2,"theme":"dark"}'::jsonb,
            'while setting the same one again replaces just that one');

select t_ok(public.set_settings('{"theme":"light"}'::jsonb) ? 'sfx',
            'and the call hands back the whole blob, not the patch');

select t_raises('select public.set_settings(''"nope"''::jsonb)',
                'must be an object', 'a patch that is not an object is refused');

-- Nobody else's, and nobody's while signed out.
select public.set_settings('{"theme":"dark"}'::jsonb);
select set_config('app.uid','b2220000-0000-0000-0000-00000000002b',false);
select public.set_settings('{"theme":"light"}'::jsonb);
select t_ok(t_settings('a2220000-0000-0000-0000-00000000002a')->>'theme' = 'dark'
            and t_settings('b2220000-0000-0000-0000-00000000002b')->>'theme' = 'light',
            'two accounts keep two themes');
select set_config('app.uid','',false);
select t_raises('select public.set_settings(''{"theme":"dark"}''::jsonb)',
                'not signed in', 'and a stranger cannot set anybody''s');

-- ---- whichever door it came in by -------------------------------------------
-- The update policy still lets a client write its own row directly, so the
-- function is the pleasant path and not the only one. 0016 learned this about
-- the avatar; the trigger below is the same lesson.
update public.profiles set settings = '{"sfx":99,"theme":"bananas"}'::jsonb
 where id = 'a2220000-0000-0000-0000-00000000002a';
select t_ok(t_settings('a2220000-0000-0000-0000-00000000002a')
            = '{"sfx":1,"theme":"system"}'::jsonb,
            'a direct write is cleaned on the way in, the same as a patch');
update public.profiles set settings = '"rubbish"'::jsonb
 where id = 'a2220000-0000-0000-0000-00000000002a';
select t_ok(t_settings('a2220000-0000-0000-0000-00000000002a') = '{}'::jsonb,
            'and rubbish written straight at the column becomes nothing');

-- ---- an account from before this migration ----------------------------------
-- The column is NOT NULL with a default, so an existing row got '{}' rather
-- than null. Belt and braces anyway: everything the client reads goes through
-- a default, the same way `acts` and `spent` do.
select t_ok((select count(*) from public.profiles where settings is null) = 0,
            'no profile anywhere has null settings');
