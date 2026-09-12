-- 0023: ability text in two languages.
--
-- Short, because there is almost no logic to test -- it is a column and eleven
-- updates. What IS worth pinning is the shape the client depends on: that
-- every live card has both languages, that the Spanish is actually Spanish
-- rather than a copy of the English, and that nothing else about a card moved.
--
-- The interesting case is the one the client handles rather than the database:
-- a null ability_es falls back to English. That is asserted here as a fact
-- about the column being NULLABLE, and in the client's own tests as behaviour.
\set ON_ERROR_STOP on
\pset pager off

-- ---- the column ------------------------------------------------------------
select t_ok((select count(*) from information_schema.columns
              where table_schema = 'public' and table_name = 'cards'
                and column_name = 'ability_es') = 1,
            'cards carry a Spanish ability');
select t_ok((select is_nullable from information_schema.columns
              where table_schema = 'public' and table_name = 'cards'
                and column_name = 'ability_es') = 'YES',
            'and it is allowed to be missing -- the client falls back to English');

-- There is no ability_en, on purpose: `ability` IS the English one and has
-- been since 0005. Renaming a column that cn_army, deck_of and random_deck all
-- read, to gain a suffix, is a migration that can only break things.
select t_ok((select count(*) from information_schema.columns
              where table_schema = 'public' and table_name = 'cards'
                and column_name = 'ability_en') = 0,
            'and there is no ability_en -- `ability` is it');

-- ---- every live card says something, in both -------------------------------
select t_ok((select count(*) from public.cards
              where is_active and coalesce(ability, '') = '') = 0,
            'every live card has an English ability');
select t_ok((select count(*) from public.cards
              where is_active and coalesce(ability_es, '') = '') = 0,
            'and a Spanish one');
select t_ok((select count(*) from public.cards
              where is_active and ability = ability_es) = 0,
            'and the two are never the same string');

-- ---- it is the spec's text, not the old prose ------------------------------
-- Both languages come from the roster spec in project_status.md section 6.
-- Spot-checked rather than compared whole: a test that repeated all eleven
-- sentences would be a second copy of them to keep in step, which is the thing
-- the single source of truth exists to avoid.
select t_ok((select ability from public.cards where slug = 'lium')
              like 'Always Ready%',
            'Lium''s English is the spec''s, not the old prose');
select t_ok((select ability_es from public.cards where slug = 'lium')
              like 'Siempre Atento%',
            'and his Spanish is the spec''s too');
select t_ok((select ability from public.cards where slug = 'dione-grifo')
              like 'Back to Back%',
            'and so is Dione & Grifo''s');
select t_ok((select ability from public.cards where slug = 'mako')
              not like 'Gone before you turn round%',
            'the prose these cards used to carry is gone');

-- The markers are metadata about the KIND of thing, and the Spanish table has
-- no equivalent, so neither language keeps them.
select t_ok((select count(*) from public.cards
              where is_active and (ability like '%**%' or ability_es like '%**%')) = 0,
            'no markdown survived the trip out of the spec');
select t_ok((select count(*) from public.cards
              where is_active and (ability like 'A:%' or ability like 'P:%')) = 0,
            'and no A: or P: marker either');

-- ---- and nothing else about a card moved ------------------------------------
-- 0023 touches two text columns. If it has quietly changed a stat, every
-- balance assertion in 09 and 10 was testing a different game than this one.
--
-- Eighty, and NOT the eighty-five the roster spec gives him. The spec's STATS
-- differ from the live roster in the same way its ability text did -- it
-- describes the roster after the rework, and Dereo is a 70-hit-point unit here
-- against the spec's 110-hit-point Royal. Jared asked for the descriptions to
-- be replaced, and only the descriptions were: a migration that quietly
-- retuned eleven cards while claiming to translate them would be the worst
-- kind. This assertion is the guard on that, which is why it carries the live
-- number rather than the spec's.
-- ...and 0031 is the migration that WAS allowed to, because restating the
-- roster to the spec is the whole of what it does. Lium is the spec's 85 now.
-- The assertion stays, pinned to the new number: it is still the guard, it is
-- simply guarding a roster that has finally caught up with its own text.
select t_ok((select hp from public.cards where slug = 'lium') = 85,
            'and Lium finally has the hit points the spec always gave him');
select t_ok((select hp from public.cards where slug = 'dereo') = 110,
            'and Dereo is the spec''s 110-point Royal at last');
select t_ok((select count(*) from public.cards where is_active) = 11,
            'and the roster is still eleven cards');
