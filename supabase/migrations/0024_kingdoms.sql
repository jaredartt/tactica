-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0023 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0024 - ten kingdoms instead of one team
--
--  A player has had exactly one saved deck since 0005, in profiles.deck. They
--  get ten now, each with a name they choose and one of the roster's tokens as
--  its icon, and one of them is selected -- and the selected one is what every
--  mode fields.
--
--  THE SHAPE
--
--    profiles.kingdoms  jsonb, a list of
--                       { id, name, icon, deck: [slug, ...] }
--    profiles.kingdom   text, the id of the selected one
--
--  A list rather than a table, for the same reason settings is a blob rather
--  than a column each: ten short rows that only their owner ever reads, always
--  read together, never joined against anything. A table would buy a foreign
--  key and cost a migration every time a kingdom grows a field.
--
--  AN INCOMPLETE KINGDOM IS LEGAL, AND THAT IS THE WHOLE DESIGN.
--
--  With one deck, "a team saves itself the moment it is a team" worked: taking
--  a card out left the last saved team in place and nothing was lost. With ten
--  it does not. Building a second kingdom means sitting at one, two, three
--  cards for as long as it takes to choose, and a store that will not hold
--  that is a store that forgets what you were doing every time you leave the
--  page.
--
--  So the column holds a half-built kingdom happily, and being FIELDABLE is a
--  separate question asked at the point of use: deck_of() wants exactly five
--  live cards and exactly one crown, and falls back to the default if it does
--  not get them. That split is what lets the editor be relaxed and the match
--  be strict.
--
--  The one thing save_kingdom DOES refuse is a COMPLETE deck that breaks the
--  royal rule -- five cards with two crowns, or none. An incomplete deck has
--  not made its mind up; a complete illegal one has, and telling somebody at
--  the moment they finish is far better than silently fielding something else
--  when the match starts.
--
--  profiles.deck is kept in step rather than retired. Everything that still
--  reads the column keeps getting the right answer, and deck_of falls back to
--  it for a profile the backfill somehow missed. It is written only ever
--  alongside the kingdoms list, never on its own.
-- ===========================================================================

alter table public.profiles
  add column if not exists kingdoms jsonb not null default '[]'::jsonb;
alter table public.profiles
  add column if not exists kingdom text;

-- ---------------------------------------------------------------------------
-- 1. how many, and how long a name
-- ---------------------------------------------------------------------------
create or replace function public.cn_kingdom_cap() returns int
language sql immutable as $$ select 10 $$;
grant execute on function public.cn_kingdom_cap() to authenticated, anon;

create or replace function public.cn_kingdom_name_max() returns int
language sql immutable as $$ select 24 $$;

-- ---------------------------------------------------------------------------
-- 2. what a kingdoms list is allowed to be
--
-- Same bargain as cn_clean_settings: repair what can be repaired, drop what
-- cannot, and never raise -- this runs on a trigger as well as on a function
-- call, and a profile you cannot save because one field is odd is a profile
-- you cannot use.
--
-- An unnamed kingdom keeps a null name rather than being given one here. The
-- name it shows is "Kingdom 3", and which words those are is a question about
-- the reader's language -- so the client answers it. A default written into
-- the database would be English in a Spanish account forever.
-- ---------------------------------------------------------------------------
create or replace function public.cn_clean_kingdoms(p jsonb)
returns jsonb language plpgsql stable as $$
declare
  k jsonb; v_out jsonb := '[]'::jsonb; v_ids text[] := '{}';
  v_id text; v_name text; v_icon text; v_deck text[]; v_clean text[];
  s text;
begin
  if p is null or jsonb_typeof(p) <> 'array' then return '[]'::jsonb; end if;

  for k in select * from jsonb_array_elements(p) loop
    exit when jsonb_array_length(v_out) >= cn_kingdom_cap();
    continue when jsonb_typeof(k) <> 'object';

    -- An id is how the client names one across a rename and a reorder, so a
    -- kingdom without one is not a kingdom; a duplicate is the second copy of
    -- somebody's double-tap.
    v_id := nullif(btrim(coalesce(k->>'id', '')), '');
    continue when v_id is null or length(v_id) > 40;
    continue when v_id = any(v_ids);
    v_ids := v_ids || v_id;

    v_name := nullif(btrim(coalesce(k->>'name', '')), '');
    if v_name is not null then
      v_name := left(v_name, cn_kingdom_name_max());
    end if;

    -- An icon is one of the roster's own tokens, checked the same way an
    -- avatar is in 0016. Anything else becomes nothing rather than a broken
    -- picture.
    v_icon := nullif(btrim(coalesce(k->>'icon', '')), '');
    if v_icon is not null
       and not exists (select 1 from public.cards where is_active and slug = v_icon) then
      v_icon := null;
    end if;

    v_clean := '{}';
    if jsonb_typeof(k->'deck') = 'array' then
      for s in select jsonb_array_elements_text(k->'deck') loop
        exit when coalesce(array_length(v_clean, 1), 0) >= deck_size();
        continue when s is null or s = any(v_clean);
        continue when not exists (select 1 from public.cards where is_active and slug = s);
        v_clean := v_clean || s;
      end loop;
    end if;

    v_out := v_out || jsonb_build_object(
      'id', v_id, 'name', v_name, 'icon', v_icon,
      'deck', to_jsonb(coalesce(v_clean, '{}'::text[])));
  end loop;

  return v_out;
end $$;

-- The selected id, kept honest: a selection pointing at a kingdom that is not
-- there is no selection, and the first one is a better answer than none.
create or replace function public.cn_pick_kingdom(p_kingdoms jsonb, p_id text)
returns text language sql stable as $$
  select coalesce(
    (select k->>'id' from jsonb_array_elements(coalesce(p_kingdoms, '[]'::jsonb)) k
      where k->>'id' = p_id limit 1),
    (select k->>'id' from jsonb_array_elements(coalesce(p_kingdoms, '[]'::jsonb)) k limit 1))
$$;

-- ---------------------------------------------------------------------------
-- 3. and the same rules whichever door it came in by
-- ---------------------------------------------------------------------------
create or replace function public.cn_check_kingdoms()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.kingdoms := cn_clean_kingdoms(new.kingdoms);
  new.kingdom := cn_pick_kingdom(new.kingdoms, new.kingdom);
  return new;
end $$;

drop trigger if exists profiles_kingdoms_are_sane on public.profiles;
create trigger profiles_kingdoms_are_sane
  before insert or update of kingdoms, kingdom on public.profiles
  for each row execute function public.cn_check_kingdoms();

-- ---------------------------------------------------------------------------
-- 4. the deck that is actually fielded
--
-- Spliced from 0018. The rules it applies are unchanged -- five live cards,
-- exactly one crown, otherwise the default -- and all that is new is where it
-- looks first.
-- ---------------------------------------------------------------------------
create or replace function public.selected_deck(p_user uuid) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select array(select jsonb_array_elements_text(k->'deck'))
       from public.profiles p,
            jsonb_array_elements(coalesce(p.kingdoms, '[]'::jsonb)) k
      where p.id = p_user and k->>'id' = p.kingdom
      limit 1),
    -- A profile from before this migration that the backfill did not reach.
    (select deck from public.profiles where id = p_user))
$$;

create or replace function public.deck_of(p_user uuid) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare v_deck text[]; v_live int;
begin
  v_deck := selected_deck(p_user);
  if coalesce(array_length(v_deck, 1), 0) <> deck_size() then
    return default_deck();
  end if;
  -- a card retired from the roster since they picked it invalidates the deck
  select count(*) into v_live from public.cards
   where is_active and slug = any(v_deck);
  if v_live <> deck_size() then return default_deck(); end if;
  if deck_royals(v_deck) <> 1 then return default_deck(); end if;
  return v_deck;
end $$;

-- ---------------------------------------------------------------------------
-- 5. saving one
-- ---------------------------------------------------------------------------
create or replace function public.save_kingdom(
  p_id text, p_name text, p_icon text, p_deck text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_ks jsonb; v_found boolean := false;
  v_out jsonb := '[]'::jsonb; k jsonb; v_new jsonb; v_id text; v_n int;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_id := nullif(btrim(coalesce(p_id, '')), '');
  if v_id is null then raise exception 'a kingdom needs an id'; end if;

  -- A finished deck has made its mind up, so it is held to the rule. A
  -- half-built one has not, and refusing it would make the editor unusable.
  if coalesce(array_length(p_deck, 1), 0) = deck_size() then
    select count(distinct s) into v_n from unnest(p_deck) s;
    if v_n <> deck_size() then raise exception 'no repeats in a kingdom'; end if;
    v_n := deck_royals(p_deck);
    if v_n = 0 then raise exception 'a kingdom needs a royal'; end if;
    if v_n > 1 then raise exception 'a kingdom has exactly one royal'; end if;
  end if;

  select coalesce(kingdoms, '[]'::jsonb) into v_ks from public.profiles where id = v_uid;

  v_new := jsonb_build_object(
    'id', v_id,
    'name', nullif(btrim(coalesce(p_name, '')), ''),
    'icon', nullif(btrim(coalesce(p_icon, '')), ''),
    'deck', to_jsonb(coalesce(p_deck, '{}'::text[])));

  for k in select * from jsonb_array_elements(v_ks) loop
    if k->>'id' = v_id then v_out := v_out || v_new; v_found := true;
    else v_out := v_out || k; end if;
  end loop;

  if not v_found then
    if jsonb_array_length(v_out) >= cn_kingdom_cap() then
      raise exception 'you can have % kingdoms', cn_kingdom_cap();
    end if;
    v_out := v_out || v_new;
  end if;

  update public.profiles
     set kingdoms = v_out,
         kingdom  = coalesce(kingdom, v_id)
   where id = v_uid;

  -- profiles.deck follows the selected kingdom, never moves on its own.
  update public.profiles set deck = selected_deck(v_uid) where id = v_uid;

  select kingdoms into v_out from public.profiles where id = v_uid;
  return v_out;
end $$;
grant execute on function public.save_kingdom(text, text, text, text[]) to authenticated;

create or replace function public.delete_kingdom(p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_out jsonb := '[]'::jsonb; k jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  for k in select * from jsonb_array_elements(
             (select coalesce(kingdoms, '[]'::jsonb) from public.profiles where id = v_uid)) loop
    if k->>'id' <> p_id then v_out := v_out || k; end if;
  end loop;
  -- The trigger repoints a selection left dangling, so deleting the one you
  -- had selected lands you on another rather than on nothing.
  update public.profiles set kingdoms = v_out where id = v_uid;
  update public.profiles set deck = selected_deck(v_uid) where id = v_uid;
  select kingdoms into v_out from public.profiles where id = v_uid;
  return v_out;
end $$;
grant execute on function public.delete_kingdom(text) to authenticated;

create or replace function public.select_kingdom(p_id text)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_out text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  update public.profiles set kingdom = p_id where id = v_uid;
  update public.profiles set deck = selected_deck(v_uid) where id = v_uid;
  select kingdom into v_out from public.profiles where id = v_uid;
  return v_out;
end $$;
grant execute on function public.select_kingdom(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. the old door still opens
--
-- set_deck writes the SELECTED kingdom now. Nothing outside this file has to
-- know that the shape changed, and a client one deploy behind keeps working.
-- ---------------------------------------------------------------------------
create or replace function public.set_deck(p_deck text[])
returns text[] language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_n int; v_id text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if coalesce(array_length(p_deck, 1), 0) <> deck_size() then
    raise exception 'a deck is exactly % cards', deck_size();
  end if;
  select count(distinct s) into v_n from unnest(p_deck) s;
  if v_n <> deck_size() then raise exception 'no repeats in a deck'; end if;
  select count(*) into v_n from public.cards where is_active and slug = any(p_deck);
  if v_n <> deck_size() then raise exception 'that deck has a card that is not in the roster'; end if;

  v_n := deck_royals(p_deck);
  if v_n = 0 then raise exception 'a kingdom needs a royal'; end if;
  if v_n > 1 then raise exception 'a kingdom has exactly one royal'; end if;

  select kingdom into v_id from public.profiles where id = v_uid;
  if v_id is null then v_id := 'k1'; end if;
  perform save_kingdom(v_id, null, null, p_deck);
  return p_deck;
end $$;

-- ---------------------------------------------------------------------------
-- 7. everybody who already had a team gets it back, as their first kingdom
--
-- Only where there is nothing there yet, so running this file twice does not
-- give anybody two copies of the same army.
-- ---------------------------------------------------------------------------
update public.profiles
   set kingdoms = jsonb_build_array(jsonb_build_object(
         'id', 'k1',
         'name', null,
         'icon', deck[1],
         'deck', to_jsonb(deck))),
       kingdom = 'k1'
 where deck is not null
   and array_length(deck, 1) = public.deck_size()
   and coalesce(jsonb_array_length(kingdoms), 0) = 0;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='profiles'
      and column_name in ('kingdoms','kingdom')) = 2       as profiles_have_kingdoms,
  public.cn_kingdom_cap() = 10                             as ten_of_them,
  to_regprocedure('public.save_kingdom(text,text,text,text[])') is not null
                                                           as save_kingdom_exists,
  to_regprocedure('public.delete_kingdom(text)') is not null    as delete_kingdom_exists,
  to_regprocedure('public.select_kingdom(text)') is not null    as select_kingdom_exists,
  public.cn_clean_kingdoms('"nope"'::jsonb) = '[]'::jsonb  as rubbish_is_nothing,
  jsonb_array_length(public.cn_clean_kingdoms(
    (select jsonb_agg(jsonb_build_object('id', 'k' || g, 'deck', '[]'::jsonb))
       from generate_series(1, 40) g))) = 10               as and_never_more_than_ten,
  (select count(*) from public.profiles
    where deck is not null and array_length(deck, 1) = public.deck_size()
      and coalesce(jsonb_array_length(kingdoms), 0) = 0) = 0
                                                           as everybody_was_backfilled;
