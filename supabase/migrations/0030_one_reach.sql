-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0029 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0030 - RANGE AND REACH ARE THE SAME THING, AND A RANGE STARTS AT 1
--
--  Jared's words, and they settle two things the schema had been treating as
--  four numbers:
--
--    "range 2 means being able to attack 1 and 2 tiles far away, and range 3
--     means 1, 2, and 3 tiles far away"
--    "range and reach IS THE SAME thing"
--
--  So a unit has ONE number. N means every tile from 1 to N, for striking and
--  for answering alike, and there is no such thing as a minimum range.
--
--  WHAT WAS WRONG. Two cards had a hole in the middle of their range: Dereo
--  could hit at exactly 2 and Fey at 2 or 3, so neither could answer anything
--  standing next to it -- a mage with a sword at its throat was invulnerable
--  to the one thing that should beat it. And counter reach was its own pair of
--  columns, which is where Fey's "only something with the same reach answers"
--  came from: crmin 3, crmax 3.
--
--  The roster spec in project_status.md has ONE `RNG` column and always did.
--  Four numbers was the engine's invention, not the design's.
--
--  THE REPAIR IS IN THE TRIGGER, NOT ONLY IN THE DATA, which is the part worth
--  arguing for. Setting the eleven rows right fixes today; normalising in
--  `cn_check_card` means the admin card editor cannot reintroduce a minimum
--  range by hand next month, and means the editor has one number to show
--  rather than four boxes with an invariant between them. 0025 already repairs
--  rather than refuses where a repair is unambiguous -- it trims and
--  lower-cases -- and "a range starts at 1" is exactly that kind of rule.
--
--  WHAT THIS DOES NOT DO. It does not touch HP, damage, movement or the
--  abilities, all of which differ from the spec as well; that is the roster
--  rework, and it is a phase rather than a line. This file changes reach and
--  only reach, so that a migration named for one rule cannot quietly retune
--  eleven cards -- the same reason 14_ability_es.sql pins the live numbers.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. the rule, where a future card cannot get past it
--
-- Spliced from 0025 verbatim; the only change is the block marked below. The
-- old reach checks are gone because there is nothing left for them to check:
-- the values they guarded are now computed rather than supplied.
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

  -- ---- ONE NUMBER, AND IT STARTS AT 1 -------------------------------------
  -- `range` is THE number: it is the column the roster spec has, the one a
  -- player reads, and now the only one anybody sets. The other four are
  -- derived from it here, every time, so a row cannot be internally
  -- inconsistent however it was written -- and so the card editor can show one
  -- box instead of four with an unwritten invariant between them.
  new.range := coalesce(nullif(new.range, 0), nullif(new.rmax, 0), 1);
  if new.range < 1 or new.range > 12 then
    raise exception 'a range is 1 to 12 -- got %', new.range;
  end if;
  -- No minimum, and no separate counter reach. A unit answers anything it
  -- could have struck; that is what "range and reach are the same thing"
  -- means, and it is why these are repaired rather than refused.
  new.rmax  := new.range;
  new.rmin  := 1;
  new.crmin := 1;
  new.crmax := new.range;

  -- power is what a player reads; dmin/dmax are the dice derived from it.
  if new.power is not null and (new.power < 1 or new.power > 200) then
    raise exception 'a power is 1 to 200';
  end if;

  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 2. the eleven that are already here
--
-- The trigger does the work: touching every row is enough to normalise it,
-- and doing it that way means the repair and the rule can never disagree.
-- ---------------------------------------------------------------------------
update public.cards set updated_at = updated_at;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.cards where rmin <> 1) = 0        as no_card_has_a_hole_in_its_range,
  (select count(*) from public.cards where crmin <> 1
                                        or crmax <> rmax) = 0    as and_answers_anything_it_could_strike,
  (select count(*) from public.cards where range <> rmax) = 0    as and_reads_the_number_it_uses,
  (select rmax from public.cards where slug = 'dereo') = 2       as dereo_still_reaches_two,
  (select rmin from public.cards where slug = 'dereo') = 1       as but_can_be_got_at_from_next_door,
  (select rmax from public.cards where slug = 'fey') = 3         as fey_still_reaches_three,
  (select crmax from public.cards where slug = 'fey') = 3        as and_now_answers_across_all_three;
