-- 0032: the four cards nobody remembers.
--
-- 0031 shipped with two of its own checks reading false in production, and the
-- reason is a row this suite has had since 0001 and never once looked at.
--
-- 0001 seeds four placeholder cards -- Vanguard, Skirmisher, Archer, Bulwark --
-- with no slug, no class and a comment saying "replace these from the admin
-- panel once it exists". 0005 deactivated them (`where slug is null`) and left
-- them where they were, because a card is retired and never deleted. So the
-- table has never held only the roster: it holds the roster AND four ghosts.
--
-- Every count in 0031's verification block said `from public.cards` with no
-- WHERE, so "twenty units" counted twenty-four and "every card has a real
-- class" counted four rows that have never had one.
--
-- THE ASSERTIONS THAT WOULD HAVE CAUGHT IT ARE ABOUT EVERY ROW, NOT ABOUT THE
-- TWENTY. That is the lesson and it is why this file exists: 04_roster.sql
-- scopes itself to the twenty slugs on purpose, which is right for asserting a
-- roster and is exactly why it could not see this.
\set ON_ERROR_STOP on
\pset pager off

-- The count over every row is asserted in 01_rules.sql, before any test file
-- has written a card -- see the note there for why it cannot live here. What
-- this file asks is the durable half: the RULE, which is what stops a fifth
-- ghost being made tomorrow.
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
insert into public.cards (slug, name, role, accent, is_active)
values (null, 'A New Ghost', '', '#334455', false);
select t_ok((select count(*) from public.cards
              where name = 'A New Ghost' and role = 'knight') = 1,
            'A CARD WITH NO CLASS AT ALL IS GIVEN ONE — even a retired one, which is the bit 0031 missed');
select t_raises($$insert into public.cards (slug, name, role, accent)
                    values ('bogus', 'Bogus', 'archer', '#334455')$$,
                'a class is one of', 'while a class that is not a class is still refused outright');
select set_config('request.jwt.claims', '', false);

-- The ghosts are still there, and staying there. They are referenced by
-- nothing -- a kingdom points at a card by slug and these have none -- but a
-- migration that DELETES rows is a migration that makes the dashboard ask
-- "Potential issue detected", and this project has kept every card it ever had.
select t_ok((select count(*) from public.cards where slug is null) >= 4,
            'the four from 0001 are still in the table, retired rather than removed');
select t_ok((select bool_and(not is_active) from public.cards where slug is null),
            'and every one of them is inactive');

-- The playable roster is untouched by any of this.
select t_ok((select count(*) from public.cards where is_active and slug is not null) = 11,
            'and the eleven playable cards are still the eleven');
