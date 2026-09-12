-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0031 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0032 - THE FOUR CARDS NOBODY REMEMBERS
--
--  0031 went out and two of its own checks read false:
--
--      twenty_units                 false
--      every_card_has_a_real_class  false
--
--  The roster is fine. The CHECKS were wrong, and the reason is a row this
--  project has carried since its first migration and never once looked at.
--
--  0001 seeds four placeholder cards -- Vanguard, Skirmisher, Archer, Bulwark
--  -- under a comment reading "replace these from the admin panel once it
--  exists". They have no slug and no class. 0005 retired them with
--  `update public.cards set is_active = false where slug is null` and left
--  them where they were, because in this project a card is retired and never
--  deleted.
--
--  So `public.cards` has never held only the roster. It holds the roster AND
--  four ghosts. Every count in 0031's verification block read
--  `from public.cards` with no WHERE: "twenty units" counted twenty-four, and
--  "every card has a real class" counted four rows that have never had one.
--
--  WHY NOTHING CAUGHT IT. The test suite runs 0001, so the ghosts are in the
--  test database too -- but a migration's verification block is not run by the
--  suite (run.sh sends migration output to /dev/null, because a migration that
--  applies is all it is asking about). And 04_roster.sql scopes its assertions
--  to the twenty slugs ON PURPOSE, which is right for asserting a roster and is
--  exactly why it could not see this. `23_ghosts.sql` is the file that asks
--  about EVERY ROW, and it fails without this migration.
--
--  WHAT THIS DOES
--
--  1. Gives every row a real class. The four get 'knight', which is arbitrary
--     and says so: they have no slug, so no kingdom can point at one and no
--     match can field one, and they have been inactive since 0005. What
--     matters is not which class they get but that the column stops having a
--     fifth possible value nobody declared.
--
--  2. Makes that an invariant instead of a tidy-up. The card trigger required
--     a class only on an ACTIVE card, which is how a blank one could sit there
--     for thirty-one migrations. An empty class is now filled in on the way
--     past, for active and retired rows alike, so this cannot come back.
--
--  3. Restates 0031's two broken checks, scoped the way they should have been.
--
--  It does NOT delete the ghosts. They are referenced by nothing and deleting
--  them would be defensible -- but every other card this game has ever had is
--  still in this table, and a migration that starts deleting rows is also a
--  migration that makes the dashboard ask whether you are sure.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. a class on every row, enforced rather than tidied
--
-- Spliced from 0031 verbatim. The only change is in the class block: what was
-- "refuse an active card with no class" is now "there is no such thing as a
-- card with no class", which is the rule the roster spec has always implied.
-- ---------------------------------------------------------------------------
create or replace function public.cn_check_card()
returns trigger language plpgsql as $$
begin
  new.slug := nullif(lower(btrim(coalesce(new.slug, ''))), '');
  new.name := btrim(coalesce(new.name, ''));
  new.role := lower(btrim(coalesce(new.role, '')));
  new.accent := lower(btrim(coalesce(new.accent, '')));
  new.art_url := nullif(btrim(coalesce(new.art_url, '')), '');
  new.ability := btrim(coalesce(new.ability, ''));
  new.ability_es := nullif(btrim(coalesce(new.ability_es, '')), '');

  if new.is_active and new.slug is null then
    raise exception 'a card needs a slug';
  end if;
  if new.slug is not null and new.slug !~ '^[a-z][a-z0-9-]{1,39}$' then
    raise exception 'a slug is lower case letters, digits and dashes: %', new.slug;
  end if;
  if new.is_active and new.name = '' then
    raise exception 'a card needs a name';
  end if;

  if new.accent !~ '^#[0-9a-f]{6}$' then
    raise exception 'an accent is six hex digits, like #2f4bff -- got %', new.accent;
  end if;

  -- ---- the class ----------------------------------------------------------
  -- A wrong class is still refused: it is what the Royal auras match on, and a
  -- sixth one spelled by hand would be a card no resistance could ever see.
  if new.role <> '' and not (new.role = any(cn_classes())) then
    raise exception 'a class is one of %, got %',
      array_to_string(cn_classes(), ', '), new.role;
  end if;
  -- But an EMPTY one is filled in rather than refused, and for retired rows as
  -- well as live ones. 0031 asked for a class only when a card was active,
  -- which is how four rows from 0001 sat in this table for thirty-one
  -- migrations with no kind at all -- and how two of 0031's own checks came to
  -- read false. Every card is something.
  if new.role = '' then new.role := 'knight'; end if;
  new.flies := (new.role = 'flying');
  new.royal := (new.role = 'royal');

  if new.mov < 0 or new.mov > 12 then
    raise exception 'a move is 0 to 12';
  end if;

  -- ---- one reach number, and it starts at 1 (0030) ------------------------
  new.range := coalesce(nullif(new.range, 0), nullif(new.rmax, 0), 1);
  if new.range < 1 or new.range > 12 then
    raise exception 'a range is 1 to 12 -- got %', new.range;
  end if;
  new.rmax  := new.range;
  new.rmin  := 1;
  new.crmin := 1;
  new.crmax := new.range;

  -- ---- and one damage number, with the dice around it (0031) --------------
  if new.power is not null then
    if new.power < 1 or new.power > 200 then
      raise exception 'a power is 1 to 200';
    end if;
    new.dmin := greatest(0, new.power - cn_spread());
    new.dmax := new.power + cn_spread();
    new.attack := new.power;
  end if;

  -- ---- the aura (0031) ----------------------------------------------------
  if new.aura_kind is not null then
    if not new.royal then
      raise exception 'only a Royal carries an aura -- % is a %', new.name, new.role;
    end if;
    if new.aura_kind in ('resist', 'bonus')
       and not (coalesce(new.aura_class, '') = any(cn_classes())) then
      raise exception 'an aura that names a class needs one of %, got %',
        array_to_string(cn_classes(), ', '), coalesce(new.aura_class, '(null)');
    end if;
    if coalesce(new.aura_pct, 0) <= 0 then
      raise exception 'an aura with no percentage does nothing';
    end if;
  end if;

  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 2. and the four, given one
--
-- Touching the row is enough: the trigger above does the work, which means the
-- repair and the rule can never disagree about what a missing class becomes.
-- Scoped to the rows that need it so this migration cannot bump `updated_at`
-- on twenty cards it has nothing to say about.
-- ---------------------------------------------------------------------------
update public.cards set updated_at = updated_at
 where role is null or role = ''
    or not (lower(btrim(role)) = any(public.cn_classes()));

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
--
-- The first two are 0031's, restated. "Twenty" means the twenty of the roster
-- spec, by name -- because the table holds more than the roster and always
-- has, which is the whole of what went wrong.
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.cards where slug in (
     'dereo','miah','stelaris','dione-grifo','lium','mako','eva','himanta',
     'dorme','fey','umiro','sinie','ashvar','velmor','sarrave','thalgrim',
     'nyxara','wuzu','lumea','zephyra')) = 20            as the_twenty_are_all_here,
  (select count(*) from public.cards
    where not (role = any(public.cn_classes()))) = 0     as and_now_every_row_has_a_class,
  (select count(*) from public.cards
    where is_active and slug is not null) = 11           as eleven_are_playable,
  (select count(*) from public.cards
    where slug is null and is_active) = 0                as and_no_ghost_is,
  (select count(*) from public.cards where slug is null) >= 4
                                                         as the_ghosts_are_kept_not_deleted,
  (select hp = 110 and power = 30 and royal
     from public.cards where slug = 'dereo')             as dereo_is_still_the_specs_royal,
  (select count(*) from public.cards where royal and is_active) = 1
                                                         as and_still_the_only_playable_crown;
