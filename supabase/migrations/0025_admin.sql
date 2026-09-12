-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0024 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0025 - the card editor's guard rails, and somewhere to put the art
--
--  MOST OF THE ADMIN EDITOR ALREADY EXISTS, which is worth saying before
--  anything else. `profiles.is_admin` has been a column since 0001, a trigger
--  since 0001 stops anybody promoting themselves, and the RLS policy "admins
--  write cards" has let an admin write the roster since 0001 as well. There is
--  no new permission here and no new door.
--
--  What does not exist is any answer to the question "what should an admin be
--  prevented from doing by accident", and the answers matter more than they
--  look:
--
--    RETIRING THE LAST ROYAL ends the game. deck_of() refuses a deck without
--    exactly one crown and hands back default_deck(); default_deck() is the
--    first five by sort, crown or no crown; and the match-over test in 0018
--    asks whether a side still has a royal on the board. A roster with no
--    royal in it is a match that CANNOT END -- both armies field a crownless
--    five, nobody can lose, and the only way out is the clock. One `update
--    cards set is_active = false` away.
--
--    DROPPING BELOW FIVE ACTIVE CARDS does the same thing more obviously:
--    default_deck() returns four, cn_army places four, and every deck in every
--    account is suddenly the wrong length.
--
--    A SEVEN-CHARACTER HEX is not a colour. `--ink: #ecectf4` was a real typo
--    in this project's dark palette and it was caught by a script that
--    asserted before writing. An accent comes out of this table and is written
--    straight into a style attribute, so it is checked here for the same
--    reason.
--
--  So this migration is a trigger, a statement-level trigger, and a bucket.
--
--  THERE IS DELIBERATELY NO FUNCTION THAT GRANTS ADMIN. Being able to hand out
--  the flag from the client is the only genuinely dangerous thing in this
--  file's neighbourhood, and it is not needed: Jared sets his own row once,
--  in the dashboard, with `update public.profiles set is_admin = true where
--  id = '<his uuid>'`. A door nobody needs is a door nobody has to defend.
--
--  Retiring rather than deleting, always. A card is referenced by slug from
--  every saved kingdom and copied by value into every live match, so a DELETE
--  would leave kingdoms pointing at nothing (cn_clean_kingdoms drops those, so
--  somebody's team quietly loses a member) while the matches already running
--  carry on with their snapshot. `is_active = false` is the honest retirement:
--  it stops the card being picked and leaves everything that already picked it
--  alone.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. what a card is allowed to be
--
-- A BEFORE trigger rather than a pile of check constraints, for the same
-- reason cn_clean_settings is a function: some of this is repair (trim a name,
-- lowercase a slug) and a constraint can only refuse. What cannot be repaired
-- is refused with a sentence rather than a constraint name, because the person
-- reading it is editing a card, not debugging a database.
-- ---------------------------------------------------------------------------
create or replace function public.cn_check_card()
returns trigger language plpgsql as $$
begin
  new.slug := nullif(lower(btrim(coalesce(new.slug, ''))), '');
  new.name := btrim(coalesce(new.name, ''));
  new.role := btrim(coalesce(new.role, ''));
  new.accent := lower(btrim(coalesce(new.accent, '')));
  new.art_url := nullif(btrim(coalesce(new.art_url, '')), '');
  new.ability := btrim(coalesce(new.ability, ''));
  new.ability_es := nullif(btrim(coalesce(new.ability_es, '')), '');

  -- A card with no slug cannot be put in a kingdom, fielded, or drawn -- every
  -- one of those looks a card up by slug. It is allowed to be null only on a
  -- row from before 0005, which 0005 deactivated on its way past.
  if new.is_active and new.slug is null then
    raise exception 'a card needs a slug';
  end if;
  if new.slug is not null and new.slug !~ '^[a-z][a-z0-9-]{1,39}$' then
    raise exception 'a slug is lower case letters, digits and dashes: %', new.slug;
  end if;
  if new.is_active and new.name = '' then
    raise exception 'a card needs a name';
  end if;

  -- The accent is written straight into a style attribute. Seven characters
  -- of hex is not a colour and it fails silently on screen.
  if new.accent !~ '^#[0-9a-f]{6}$' then
    raise exception 'an accent is six hex digits, like #2f4bff -- got %', new.accent;
  end if;

  if new.mov < 0 or new.mov > 12 then
    raise exception 'a move is 0 to 12';
  end if;
  if new.rmin < 1 or new.rmax < new.rmin or new.rmax > 12 then
    raise exception 'a reach runs from at least 1 up to at most 12, low end first';
  end if;
  if new.crmin < 0 or new.crmax < new.crmin or new.crmax > 12 then
    raise exception 'a counter reach runs low end first, and no further than 12';
  end if;
  -- power is what a player reads; dmin/dmax are the dice derived from it.
  if new.power is not null and (new.power < 1 or new.power > 200) then
    raise exception 'a power is 1 to 200';
  end if;

  new.updated_at := now();
  return new;
end $$;

drop trigger if exists cards_are_sane on public.cards;
create trigger cards_are_sane
  before insert or update on public.cards
  for each row execute function public.cn_check_card();

-- ---------------------------------------------------------------------------
-- 2. and what the ROSTER is allowed to be
--
-- Per statement, not per row: "is there still a royal" is a question about the
-- table after the whole update has landed, and a row-level trigger asking it
-- half way through a two-row swap would answer about a state that never
-- existed. An AFTER trigger raising here rolls the statement back whole.
--
-- It counts rather than caches. Twenty rows read once per roster edit is
-- nothing, and a cached count is a number that can be wrong.
-- ---------------------------------------------------------------------------
create or replace function public.cn_roster_is_playable()
returns trigger language plpgsql as $$
declare v_live int; v_crowns int;
begin
  select count(*), count(*) filter (where royal)
    into v_live, v_crowns
    from public.cards where is_active and slug is not null;

  if v_live < deck_size() then
    raise exception 'the roster would be down to % cards, and a kingdom is %',
                    v_live, deck_size();
  end if;
  -- Losing the last crown is the one that does not look like a mistake. A
  -- match ends when a side loses its royal; with no royal in the roster both
  -- armies field a crownless five and nobody can win.
  if v_crowns < 1 then
    raise exception 'the roster would have no royal left, and a match with no royal cannot end';
  end if;
  return null;
end $$;

drop trigger if exists cards_leave_a_game on public.cards;
create trigger cards_leave_a_game
  after insert or update or delete on public.cards
  for each statement execute function public.cn_roster_is_playable();

-- ---------------------------------------------------------------------------
-- 3. somewhere to put the art
--
-- Wrapped in a check for the storage schema, because the test harness fakes
-- the parts of Supabase the migrations need and has no storage at all. A
-- migration that only applies in production is a migration nothing tests; one
-- that refuses to apply anywhere else is a suite that cannot run.
--
-- The bucket is PUBLIC to read on purpose. Card art is drawn by every player
-- in every match and is not a secret; a signed URL per token per frame would
-- be a lot of machinery to hide a picture of a knight.
-- ---------------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    raise notice 'no storage schema here -- skipping the art bucket';
    return;
  end if;

  insert into storage.buckets (id, name, public)
  values ('art', 'art', true)
  on conflict (id) do update set public = true;

  execute $p$drop policy if exists "art is readable by anyone" on storage.objects$p$;
  execute $p$create policy "art is readable by anyone"
             on storage.objects for select
             using (bucket_id = 'art')$p$;

  execute $p$drop policy if exists "admins write art" on storage.objects$p$;
  execute $p$create policy "admins write art"
             on storage.objects for all to authenticated
             using (bucket_id = 'art'
                    and exists (select 1 from public.profiles p
                                 where p.id = auth.uid() and p.is_admin))
             with check (bucket_id = 'art'
                    and exists (select 1 from public.profiles p
                                 where p.id = auth.uid() and p.is_admin))$p$;
end $$;

-- ---------------------------------------------------------------------------
-- 4. is anybody an admin yet?
--
-- Nothing here grants it. This only says out loud whether the flag has been
-- set, so that running this file and then finding the editor greyed out is not
-- a mystery. Set it once, by hand, in the dashboard:
--
--   update public.profiles set is_admin = true where id = '<your uuid>';
-- ---------------------------------------------------------------------------
do $$ declare n int; begin
  select count(*) into n from public.profiles where is_admin;
  if n = 0 then
    raise notice 'no admin yet -- set profiles.is_admin on your own row by hand';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  to_regprocedure('public.cn_check_card()') is not null        as card_guard_exists,
  to_regprocedure('public.cn_roster_is_playable()') is not null as roster_guard_exists,
  (select count(*) from pg_trigger
    where tgrelid = 'public.cards'::regclass
      and tgname in ('cards_are_sane', 'cards_leave_a_game')) = 2
                                                              as both_triggers_on,
  (select count(*) from public.cards where is_active and royal) >= 1
                                                              as the_roster_still_has_a_crown,
  (select count(*) from public.cards where is_active) >= public.deck_size()
                                                              as and_enough_cards_for_a_kingdom,
  (select count(*) from public.cards
    where is_active and accent !~ '^#[0-9a-f]{6}$') = 0        as every_accent_is_a_colour;
