-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0025 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0026 - who they brought, how long the fight takes, and two ladder columns
--
--  Three small things that happen to need the same migration.
--
--  1. WHO THEY BROUGHT. Deployment has been blind since 0008 -- neither side
--     can see the other's half of the board, which is the whole point of it.
--     It has also been blind about WHICH FIVE, and that part was never the
--     point. Knowing that the other side has brought the archer changes where
--     you put your mage; knowing WHERE the archer is standing would make the
--     phase pointless. So `their_army()` hands back the identities and not one
--     coordinate, and it only answers while the match is still deploying --
--     after that the board says everything anyway.
--
--     It is deliberately not a view or a policy. match_deploy has no SELECT
--     policy at all and should keep none: a function that returns four fields
--     of each row is a much smaller thing to get right than a policy that has
--     to hide two.
--
--  2. HOW LONG THE FIGHT TAKES. `cine` joins the settings blob: 'full',
--     'quick' or 'off'. No new column -- 0022's cleaner keeps keys it does not
--     recognise, which is exactly so that a client can be a deploy ahead of
--     the database -- but a KNOWN key is a validated one, so it is added to
--     the cleaner here.
--
--     THE CLOCK DOES NOT CHANGE, and that is worth writing down because it
--     looks like an oversight. 0021 pushes the turn deadline by the length of
--     the FULL cinematic, and it goes on doing that whatever this setting
--     says. Somebody who turns it off gets that time back as thinking time --
--     which is exactly what the Skip button has done since Phase C shipped.
--     Making the server compute a different deadline per side would mean
--     leaking a preference into a shared clock to close a hole that is already
--     open by design.
--
--  3. TWO LADDER COLUMNS. The leaderboard view never selected `avatar`, so the
--     client's LadderRow has had an `avatar` field with nothing behind it
--     since 0016. And `tournaments` is Phase E's stat, added now so the shape
--     is settled before anything fills it. It reads 0 for everybody until
--     Phase E exists, which is honest rather than padding: the column is where
--     the tournament code will write, and a ladder that grows a column later
--     is a ladder that shifts under everybody once.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. which five they brought
-- ---------------------------------------------------------------------------
create or replace function public.their_army(p_match uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare m public.matches; v_side text; v_them text; v_units jsonb;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null then return null; end if;

  -- A spectator gets nothing. Deployment is secret from the room as well as
  -- from the other player -- anyone watching could otherwise relay it.
  v_side := side_of(m, auth.uid());
  if v_side is null then return null; end if;

  -- Only while it is still a secret worth keeping. Once the match is running
  -- both armies are in matches.state and this function has nothing to add.
  if m.status <> 'deploying' then return null; end if;

  v_them := case when v_side = 'host' then 'guest' else 'host' end;
  select units into v_units from public.match_deploy
   where match_id = p_match and side = v_them;
  if v_units is null then return '[]'::jsonb; end if;

  -- Identity and nothing else. NOT `u - 'x' - 'y'`: subtracting the two keys
  -- that are secret today leaves every key added tomorrow exposed by default,
  -- and the next field on a unit will be added by somebody thinking about
  -- combat rather than about this function. Listing what goes out is the only
  -- version of this that stays correct on its own.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',   u->>'id',
           'slug', u->>'slug',
           'name', u->>'name',
           'role', u->>'role',
           'art',  u->>'art',
           'maxHp', (u->>'maxHp')::int
         ) order by u->>'id'), '[]'::jsonb)
    into v_units
    from jsonb_array_elements(v_units) u;
  return v_units;
end $$;
grant execute on function public.their_army(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. how long the fight takes
--
-- Spliced from 0022 rather than rewritten: every other branch here is
-- unchanged and a hand-retyped validator is a validator with one branch
-- quietly different.
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
  -- The cinematic. DROPPED rather than defaulted when it is something else,
  -- which is the opposite of what `theme` does and is the difference between
  -- them: every theme is a theme somebody might want, so an unknown one lands
  -- on the sensible default. An unknown `cine` is a value from a build that
  -- knows something this database does not, and quietly rewriting it to 'full'
  -- would turn a newer client's preference into an older server's opinion.
  if v ? 'cine' and coalesce(v->>'cine', '') not in ('full', 'quick', 'off') then
    v := v - 'cine';
  end if;

  -- A preferences blob has no business being large. This is not a rule about
  -- settings, it is a rule about a text column somebody could write a novel
  -- into: past the cap the whole thing is refused rather than truncated,
  -- because half a JSON document is not a smaller JSON document.
  if length(v::text) > 4000 then return '{}'::jsonb; end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 3. the ladder grows two columns
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists tournaments int not null default 0
  check (tournaments >= 0);

drop view if exists public.leaderboard;
create view public.leaderboard
with (security_invoker = true) as
  select p.id, p.username, p.avatar, p.lp, tier_of(p.lp) as tier,
         p.wins, p.losses, p.games, p.streak, p.tournaments
    from public.profiles p
   where p.games > 0;
grant select on public.leaderboard to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  to_regprocedure('public.their_army(uuid)') is not null       as their_army_exists,
  public.cn_clean_settings('{"cine":"quick"}'::jsonb)
    = '{"cine":"quick"}'::jsonb                                as quick_is_a_setting,
  public.cn_clean_settings('{"cine":"bananas"}'::jsonb) = '{}'::jsonb
                                                               as and_nonsense_is_not,
  public.cn_clean_settings('{"theme":"dark","sfx":0.5}'::jsonb)
    = '{"sfx":0.5,"theme":"dark"}'::jsonb                      as everything_else_unchanged,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='profiles'
      and column_name='tournaments') = 1                       as profiles_count_tournaments,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='leaderboard'
      and column_name in ('avatar','tournaments')) = 2         as the_ladder_shows_both;
