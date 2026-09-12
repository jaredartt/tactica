-- 0025: the card editor's guard rails.
--
-- Almost none of the admin editor is new -- profiles.is_admin, the trigger
-- that stops self-promotion and the RLS policy that lets an admin write the
-- roster have all been there since 0001, and 01_rules.sql and 08_profile.sql
-- already cover them. What is new is what an admin must not be able to do BY
-- ACCIDENT, and the two that matter are not obvious from the outside:
--
--   Retire the last royal, and a match can no longer end. deck_of refuses a
--   crownless deck and falls back to default_deck(), default_deck is the first
--   five by sort whether or not a crown is among them, and the win condition
--   in 0018 asks whether a side still has a royal ON THE BOARD. So both armies
--   field five commoners and nobody can win.
--
--   Drop below five active cards and every deck in every account is the wrong
--   length at once.
--
-- Neither looks like a mistake while you are making it. That is what the
-- statement-level trigger is for, and most of this file is about it.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('e1110000-0000-0000-0000-00000000001e','boss@x.com','{"username":"boss"}'),
  ('f1110000-0000-0000-0000-00000000001f','pleb@x.com','{"username":"pleb"}');
-- As the SERVICE ROLE, because that is the only thing that can set this flag:
-- 0001's trigger reverts an is_admin change made by anybody else, whoever they
-- are and whatever row they are editing. It is also exactly how Jared grants
-- it -- the dashboard's SQL editor runs as service_role -- so the test and the
-- instruction in 0025's header are the same act.
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
update public.profiles set is_admin = true where id = 'e1110000-0000-0000-0000-00000000001e';
select set_config('request.jwt.claims', '', false);

-- Who was live before this file started pushing them around. Recorded rather
-- than assumed: "turn everything back on" would resurrect cards that earlier
-- migrations retired on purpose, and the count at the end would be right for
-- the wrong roster.
create temporary table t_was as select slug from public.cards where is_active;

create or replace function t_cardcount() returns int
language sql stable as $$ select count(*)::int from public.cards where is_active $$;
create or replace function t_crowns() returns int
language sql stable as $$ select count(*)::int from public.cards where is_active and royal $$;
-- A spare card to push around, so nothing in this file has to edit one of the
-- eleven the rest of the suite is asserting about.
create or replace function t_spare() returns void language sql as $$
  insert into public.cards (slug, name, role, hp, mov, rmin, rmax, crmin, crmax,
                            dmin, dmax, power, accent, sort, is_active)
  -- 'knight' rather than 'Test': since 0031 a class is one of five checked
  -- values, and a spare card has to be a real kind of thing like any other.
  values ('t-spare', 'Spare', 'knight', 80, 2, 1, 1, 1, 1, 15, 25, 20, '#123456', 99, true)
  on conflict (slug) do update set is_active = true;
$$;

-- ---- the guards exist ------------------------------------------------------
select t_ok(to_regprocedure('public.cn_check_card()') is not null,
            'a card is checked on the way in');
select t_ok(to_regprocedure('public.cn_roster_is_playable()') is not null,
            'and the roster is checked on the way out');
select t_ok((select count(*) from pg_trigger
              where tgrelid = 'public.cards'::regclass
                and tgname in ('cards_are_sane', 'cards_leave_a_game')) = 2,
            'both of them are actually attached');

-- ---- what a card is allowed to be ------------------------------------------
select t_spare();
select t_ok(t_cardcount() = 12, 'the spare card is in');

-- The accent is written straight into a style attribute, and seven characters
-- of hex is not a colour -- it fails silently on screen, which is how
-- `--ink: #ecectf4` survived long enough to be worth a check.
select t_raises('update public.cards set accent = ''#ecectf4'' where slug = ''t-spare''',
                'six hex digits', 'a seven-digit hex is not a colour');
select t_raises('update public.cards set accent = ''blue'' where slug = ''t-spare''',
                'six hex digits', 'and neither is the word blue');
update public.cards set accent = '#2F4BFF' where slug = 't-spare';
select t_ok((select accent from public.cards where slug = 't-spare') = '#2f4bff',
            'a colour in capitals is repaired rather than refused');

update public.cards set slug = '  T-Spare  ' where slug = 't-spare';
select t_ok((select count(*) from public.cards where slug = 't-spare') = 1,
            'a slug is trimmed and lower-cased on the way in');
select t_raises('update public.cards set slug = ''no spaces'' where slug = ''t-spare''',
                'lower case letters', 'a slug with a space in it is refused');
select t_raises('insert into public.cards (name, accent) values (''Nameless'', ''#111111'')',
                'needs a slug', 'a live card with no slug at all is refused');
select t_raises('update public.cards set name = ''   '' where slug = ''t-spare''',
                'needs a name', 'and so is one with no name');

-- 0030 turned this guard into a repair, and that is the better answer: the
-- four reach columns are DERIVED from `range` now, so they cannot disagree
-- with each other for anybody to refuse. A backwards reach is not rejected, it
-- stops existing.
update public.cards set rmax = 0, rmin = 4 where slug = 't-spare';
select t_ok((select rmin from public.cards where slug = 't-spare') = 1
        and (select rmax from public.cards where slug = 't-spare')
            = (select range from public.cards where slug = 't-spare'),
            'a reach that ends before it starts is REPAIRED now, not refused — see 0030');
select t_raises('update public.cards set range = -1 where slug = ''t-spare''',
                'a range is 1 to 12', 'while a range that is not a number of tiles still is');
select t_raises('update public.cards set mov = -1 where slug = ''t-spare''',
                'move', 'and a move backwards');
select t_raises('update public.cards set power = 5000 where slug = ''t-spare''',
                'power', 'and a power nobody could survive');

-- Repair, not refusal, for the things that can be repaired.
update public.cards set name = '  Spare  ', ability = '  does a thing  '
 where slug = 't-spare';
select t_ok((select name from public.cards where slug = 't-spare') = 'Spare'
        and (select ability from public.cards where slug = 't-spare') = 'does a thing',
            'whitespace is trimmed rather than argued about');

-- updated_at is what a client polls to notice a card has been retuned.
update public.cards set updated_at = '2001-01-01' where slug = 't-spare';
select t_ok((select updated_at from public.cards where slug = 't-spare') > now() - interval '1 minute',
            'and every write stamps updated_at, whatever the writer said');

-- ---- WHAT THE ROSTER IS ALLOWED TO BE --------------------------------------
-- The two that matter.
select t_ok(t_crowns() = 1, 'the roster has one crown to begin with');
select t_raises('update public.cards set is_active = false where royal',
                'no royal left',
                'RETIRING THE LAST ROYAL IS REFUSED — a match with no royal cannot end');
select t_ok(t_crowns() = 1, 'and the crown is still there afterwards');

-- Un-crowning by hand does not reach the statement trigger any more: since
-- 0031 `royal` is DERIVED from the class, so the write is overwritten on its
-- way in and the crown never leaves. Stronger than the refusal it replaces --
-- there is no longer a way to ask for the thing that had to be refused.
update public.cards set royal = false where royal;
select t_ok(t_crowns() = 1,
            'and un-crowning by hand does nothing at all now — the class is the crown');
-- Taking the class away trips the AURA guard first: Dereo carries one, and an
-- aura on something that is not a Royal is a card that cannot be right. So the
-- crown is guarded twice over, and both guards are worth naming.
select t_raises('update public.cards set role = ''mage'' where slug = ''dereo''',
                'only a Royal carries an aura',
                'while taking the class away trips the aura guard first');
update public.cards set aura_kind = null, aura_class = null, aura_pct = null
 where slug = 'dereo';
select t_raises('update public.cards set role = ''mage'' where slug = ''dereo''',
                'no royal left',
                'AND WITH THE AURA OUT OF THE WAY, THE ROSTER STILL REFUSES TO LOSE ITS CROWN');
update public.cards set aura_kind = 'resist', aura_class = 'knight', aura_pct = 20
 where slug = 'dereo';
select t_ok((select aura_pct from public.cards where slug = 'dereo') = 20,
            'and the aura is handed back, so nothing after this file is playing a different game');

-- Not the last one. A second crown means either may go -- and since 0031 a
-- crown is a CLASS, so the spare is promoted rather than flagged.
update public.cards set role = 'royal' where slug = 't-spare';
select t_ok(t_crowns() = 2, 'with two crowns on the roster');
update public.cards set role = 'knight' where slug = 't-spare';
select t_ok(t_crowns() = 1, 'the second one can be taken off again');

-- Everything EXCEPT the crown, so it is the SIZE rule that has to refuse this
-- and not the royal one. Retiring the lot trips both, and an assertion that
-- passes because a different rule caught it is an assertion about nothing.
select t_raises('update public.cards set is_active = false where is_active and not royal',
                'down to', 'a roster of one crown and nothing else is refused');
-- Emptying it outright breaks both rules, and the size one is asked first --
-- which is the right order to ask them in: "there is nothing left" is a more
-- useful thing to be told than "there is no crown among the nothing".
select t_raises('update public.cards set is_active = false where is_active',
                'down to 0', 'and emptying it outright is refused for the plainer reason');
select t_ok(t_cardcount() = 12, 'and the roster is untouched by either');

-- Down to exactly five is allowed; five is a kingdom.
select t_ok(public.deck_size() = 5, 'a kingdom is five');
update public.cards set is_active = false
 where is_active and slug not in (select slug from public.cards
                                   where is_active order by royal desc, sort limit 5);
select t_ok(t_cardcount() = 5, 'a roster of exactly five is allowed');
select t_ok(t_crowns() = 1, 'with its crown');
select t_raises('update public.cards set is_active = false
                  where slug = (select slug from public.cards where is_active and not royal
                                 order by sort limit 1)',
                'down to', 'and a sixth retirement is refused');
-- `where slug is not null`, because a row from before 0005 has no slug and
-- `null in (...)` is null, not false -- which is a NOT NULL violation rather
-- than the tidy no-op it looks like.
update public.cards set is_active = (slug in (select slug from t_was))
 where slug is not null;
select t_ok(t_cardcount() = (select count(*) from t_was),
            'and everybody who was live before is live again -- and nobody else');
select t_ok(t_cardcount() = 11, 'which is eleven');

-- ---- whichever door it came in by ------------------------------------------
-- The RLS policy lets an admin write the table directly, so the guard has to
-- be a trigger. 01_rules.sql already checks that a non-admin cannot get in at
-- all; this checks that getting in does not mean getting past the rules.
select set_config('app.uid','e1110000-0000-0000-0000-00000000001e',false);
select t_ok((select is_admin from public.profiles
              where id = 'e1110000-0000-0000-0000-00000000001e'),
            'the admin is an admin');
select t_raises('update public.cards set accent = ''#xyz'' where slug = ''dereo''',
                'six hex digits', 'and is held to the same rules as anybody');

-- Nobody promotes themselves. 0001 has done this since the beginning; it is
-- repeated here because 0025 is the migration that makes the flag WORTH
-- having, and a privilege check nobody re-reads is a privilege check.
select set_config('app.uid','f1110000-0000-0000-0000-00000000001f',false);
update public.profiles set is_admin = true
 where id = 'f1110000-0000-0000-0000-00000000001f';
select t_ok(not (select is_admin from public.profiles
                  where id = 'f1110000-0000-0000-0000-00000000001f'),
            'AND NOBODY MAKES THEMSELVES AN ADMIN, which is the only dangerous door here');
-- Nor can the ADMIN hand it out, which is the less obvious half. 0001's
-- trigger asks for service_role and nothing else; being an admin is not a way
-- to make more of them.
select set_config('app.uid','e1110000-0000-0000-0000-00000000001e',false);
update public.profiles set is_admin = true
 where id = 'f1110000-0000-0000-0000-00000000001f';
select t_ok(not (select is_admin from public.profiles
                  where id = 'f1110000-0000-0000-0000-00000000001f'),
            'and an admin cannot make another one either');
select t_ok(to_regprocedure('public.set_admin(uuid, boolean)') is null
        and to_regprocedure('public.grant_admin(uuid)') is null,
            'there is no function that hands the flag out, on purpose');

-- ---- the art bucket --------------------------------------------------------
-- There is no storage schema in this harness -- it fakes only the parts of
-- Supabase the migrations need -- so the bucket half of 0025 is skipped there
-- by design. What is asserted is that skipping it is DELIBERATE: the migration
-- applied, which it would not have done if the storage block were unguarded.
select t_ok((select count(*) from information_schema.schemata
              where schema_name = 'storage') = 0,
            'this harness has no storage schema');
select t_ok(to_regprocedure('public.cn_check_card()') is not null,
            'and 0025 applied anyway, which is the whole point of guarding that block');

-- ---- and the eleven are still the eleven -----------------------------------
select t_ok(t_cardcount() = 11, 'the roster is eleven cards');
select t_ok((select count(*) from public.cards where is_active and accent !~ '^#[0-9a-f]{6}$') = 0,
            'and every one of them has a colour that is a colour');
