-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0021 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0022 - settings follow the account
--
--  Sound, music and reduce-motion have lived in localStorage since they were
--  built, and the comment at the top of settings.ts defended that: there is
--  nothing there another device needs to know, and a volume slider that waits
--  for a round trip feels broken.
--
--  That defence holds for a volume. It does not hold for a THEME. Signing in
--  on a phone and getting a white screen because the preference stayed on the
--  laptop is not a cache miss, it is the setting not working -- and the same
--  goes for the language toggle that comes next. So the settings move to the
--  account, and localStorage stays as a cache in front of them: the slider
--  still moves instantly, and the account is what makes it true everywhere.
--
--  One jsonb column, not a column per setting. A setting is a preference, not
--  a fact about the game, and giving each one a migration would mean a
--  migration every time a checkbox is added.
--
--  KNOWN KEYS ARE VALIDATED, UNKNOWN KEYS ARE KEPT.
--
--  That combination is the whole design and it is worth saying why. Validating
--  only what it knows means a volume cannot be 40 and a theme cannot be
--  'bananas' -- rubbish in the column would come back as a broken screen on
--  every device, not just the one that wrote it. Keeping what it does not know
--  means the day the client grows a new toggle it does NOT need a migration
--  first, and a client one deploy ahead of the database is not a client that
--  silently loses settings.
--
--  The site deploys instantly and migrations are pasted in by hand, so a
--  client ahead of the database is a normal state here, not a hypothetical.
-- ===========================================================================

alter table public.profiles
  add column if not exists settings jsonb not null default '{}'::jsonb;

-- ---------------------------------------------------------------------------
-- 1. what a settings blob is allowed to be
--
-- Anything that is not an object is not settings, and becomes an empty one.
-- Known keys are coerced into range; unknown keys ride along untouched.
-- ---------------------------------------------------------------------------
create or replace function public.cn_clean_settings(p jsonb)
returns jsonb language plpgsql immutable as $$
declare v jsonb; n numeric;
begin
  if p is null or jsonb_typeof(p) <> 'object' then return '{}'::jsonb; end if;
  v := p;

  -- Volumes are fractions. A number outside 0..1 is a bug somewhere, and the
  -- honest repair is the nearest end rather than a refusal -- refusing would
  -- lose every OTHER setting in the same patch.
  foreach n in array array[0] loop end loop;  -- (no-op; keeps the declare tidy)

  if v ? 'sfx' then
    if jsonb_typeof(v->'sfx') = 'number'
      then v := jsonb_set(v, '{sfx}', to_jsonb(least(1, greatest(0, (v->>'sfx')::numeric))));
      else v := v - 'sfx';
    end if;
  end if;
  if v ? 'music' then
    if jsonb_typeof(v->'music') = 'number'
      then v := jsonb_set(v, '{music}', to_jsonb(least(1, greatest(0, (v->>'music')::numeric))));
      else v := v - 'music';
    end if;
  end if;
  if v ? 'reduceMotion' and jsonb_typeof(v->'reduceMotion') <> 'boolean' then
    v := v - 'reduceMotion';
  end if;
  -- 'system' means "ask the operating system", which is the default and the
  -- only sensible landing place for a value nobody recognises.
  if v ? 'theme' and coalesce(v->>'theme', '') not in ('system', 'light', 'dark') then
    v := jsonb_set(v, '{theme}', '"system"'::jsonb);
  end if;
  if v ? 'lang' and coalesce(v->>'lang', '') not in ('en', 'es') then
    v := v - 'lang';
  end if;

  -- A preferences blob has no business being large. This is not a rule about
  -- settings, it is a rule about a text column somebody could write a novel
  -- into: past the cap the whole thing is refused rather than truncated,
  -- because half a JSON document is not a smaller JSON document.
  if length(v::text) > 4000 then return '{}'::jsonb; end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 2. change some of them
--
-- A PATCH and not a replacement. Two tabs open on two screens would otherwise
-- take turns wiping each other's last change, and settings are exactly the
-- thing somebody has open twice.
-- ---------------------------------------------------------------------------
create or replace function public.set_settings(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_out jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'settings must be an object';
  end if;
  update public.profiles
     set settings = cn_clean_settings(coalesce(settings, '{}'::jsonb) || p_patch)
   where id = v_uid
   returning settings into v_out;
  return coalesce(v_out, '{}'::jsonb);
end $$;
grant execute on function public.set_settings(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. and the same rules whichever door it came in by
--
-- profiles still has an UPDATE policy that lets a client write its own row, so
-- the function above is the pleasant path rather than the only one. This is
-- the belt to that brace -- exactly as 0016 did for the avatar.
-- ---------------------------------------------------------------------------
create or replace function public.cn_check_settings()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.settings := cn_clean_settings(new.settings);
  return new;
end $$;

drop trigger if exists profiles_settings_are_sane on public.profiles;
create trigger profiles_settings_are_sane
  before insert or update of settings on public.profiles
  for each row execute function public.cn_check_settings();

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='settings') = 1
                                                              as profiles_have_settings,
  to_regprocedure('public.set_settings(jsonb)') is not null    as set_settings_exists,
  public.cn_clean_settings('{"sfx":5}'::jsonb) = '{"sfx":1}'::jsonb
                                                              as a_loud_volume_is_clamped,
  public.cn_clean_settings('{"theme":"bananas"}'::jsonb) = '{"theme":"system"}'::jsonb
                                                              as a_silly_theme_is_the_default,
  public.cn_clean_settings('{"whatever":1}'::jsonb) = '{"whatever":1}'::jsonb
                                                              as unknown_keys_survive,
  public.cn_clean_settings('"nope"'::jsonb) = '{}'::jsonb      as rubbish_is_nothing;
