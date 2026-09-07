-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0010 through 0015 first. The last statement prints a row of checks;
--  every column must say true.
-- ===========================================================================
--  0016 - a face and a name you can change
--
--  Your icon is one of the roster's own tokens -- the zoomed crop the board
--  uses -- so there is nothing to upload, nothing to moderate, and no storage
--  bill. It is a card slug in a text column and the client already knows how
--  to turn a slug into a picture.
--
--  Both changes go through functions rather than the update policy, so the
--  rules live next to the data: a name is 2-20 characters and has to be free,
--  an icon has to be a card that is actually in the roster. The trigger at the
--  bottom is the belt to that pair of braces -- the update policy still lets a
--  client write its own row directly, and this makes an icon that is not a
--  real card impossible rather than merely unsupported.
-- ===========================================================================

alter table public.profiles add column if not exists avatar text;

-- ---------------------------------------------------------------------------
-- 1. pick a face
-- ---------------------------------------------------------------------------
create or replace function public.set_avatar(p_slug text)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_slug is not null
     and not exists (select 1 from public.cards where is_active and slug = p_slug) then
    raise exception 'no such card';
  end if;
  update public.profiles set avatar = p_slug where id = v_uid;
  return p_slug;
end $$;
grant execute on function public.set_avatar(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. change your name
--
-- The unique index is what actually decides it; catching the violation here
-- only turns a constraint name into a sentence a person can read.
-- ---------------------------------------------------------------------------
create or replace function public.set_username(p_name text)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_name text := btrim(p_name);
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 20 then
    raise exception 'a name is between 2 and 20 characters';
  end if;
  if v_name !~ '^[A-Za-z0-9 _.-]+$' then
    raise exception 'letters, numbers, spaces, dots, dashes and underscores only';
  end if;
  begin
    update public.profiles set username = v_name where id = v_uid;
  exception when unique_violation then
    raise exception 'that name is taken';
  end;
  return v_name;
end $$;
grant execute on function public.set_username(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. an icon is always a real card, whichever door it came in by
-- ---------------------------------------------------------------------------
create or replace function public.cn_check_avatar()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.avatar is not null
     and not exists (select 1 from public.cards where is_active and slug = new.avatar) then
    new.avatar := null;
  end if;
  return new;
end $$;

drop trigger if exists profiles_avatar_is_a_card on public.profiles;
create trigger profiles_avatar_is_a_card
  before insert or update of avatar on public.profiles
  for each row execute function public.cn_check_avatar();

-- ---------------------------------------------------------------------------
-- 4. the ladder shows faces too
-- ---------------------------------------------------------------------------
drop view if exists public.leaderboard;
create view public.leaderboard
with (security_invoker = true) as
  select p.id, p.username, p.avatar, p.lp, tier_of(p.lp) as tier,
         p.wins, p.losses, p.games, p.streak
    from public.profiles p
   where p.games > 0;
grant select on public.leaderboard to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='avatar') = 1
                                                                    as profiles_have_a_face,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='leaderboard' and column_name='avatar') = 1
                                                                    as and_the_ladder_shows_it,
  to_regprocedure('public.set_avatar(text)')   is not null           as set_avatar_exists,
  to_regprocedure('public.set_username(text)') is not null           as set_username_exists;
