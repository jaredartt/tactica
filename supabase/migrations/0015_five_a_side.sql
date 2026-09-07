-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0010 through 0014 first. The last statement prints a row of checks;
--  every column must say true.
-- ===========================================================================
--  0015 - five a side
--
--  A team is five cards instead of four. Eleven characters and a hand of four
--  meant a third of the roster went unseen in any given match; five is enough
--  that a team has a shape -- a front, an answer and a mender -- rather than
--  just four good units.
--
--  There is no data migration to do. deck_size() is the single place the
--  number lives and everything downstream asks it: how many the deployment
--  builds, how many set_deck accepts, how many the bot draws. Everyone's saved
--  four is now the wrong length, and deck_of() already treats a deck of the
--  wrong length as no deck at all and hands back the default -- so every
--  player quietly falls back to the first five until they pick again, which is
--  exactly what should happen.
--
--  The one thing that did NOT ask was default_deck(), which had `limit 4`
--  written into it. That is the bug this migration mostly exists to fix: with
--  deck_size() at 5 it would have returned four cards forever, and cn_army
--  would have raised 'unknown card' on the fifth for every player who had not
--  chosen a team.
-- ===========================================================================

create or replace function public.deck_size() returns int
language sql immutable as $$ select 5 $$;

create or replace function public.default_deck() returns text[]
language sql stable as $$
  select coalesce(array_agg(c.slug order by c.sort), '{}'::text[])
    from (select slug, sort from public.cards
           where is_active and slug is not null
           order by sort limit public.deck_size()) c
$$;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  public.deck_size() = 5                                              as five_a_side,
  array_length(public.default_deck(), 1) = 5                          as the_default_is_five,
  jsonb_array_length(
    public.cn_army(public.cn_fresh_map(), 'host', public.default_deck())) = 5
                                                                      as five_reach_the_board,
  (select count(*) = 0 from jsonb_array_elements(
     public.cn_army(public.cn_fresh_map(), 'guest', public.default_deck())) u
    where (u->>'x')::int < 3)                                         as and_all_on_their_own_side;
