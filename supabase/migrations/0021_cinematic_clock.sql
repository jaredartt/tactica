-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0020 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0021 - the clock waits for the cinematic
--
--  Phase C takes the screen while an exchange plays: two units enlarged, the
--  lunge, the parry, the answer, a caption box under each beat. It is worth
--  watching, and it is between two and six seconds of a thirty-second turn --
--  so left alone it would be charged to the attacker's thinking time, and the
--  right way to play would be to turn it off. A cinematic you are penalised
--  for watching is not a feature.
--
--  So the turn deadline is pushed by exactly as long as the cinematic runs.
--
--  Three things about where this lives, because each one is load-bearing:
--
--  1. It is in submit_attack, not cn_attack. cn_attack holds the RULES and the
--     bot calls it directly; the bot has no screen and no clock pressure, and
--     handing it extra seconds would be handing it nothing. submit_attack is
--     the human's door, and the turn clock is already that door's business --
--     it is where "your time ran out" is raised.
--
--  2. The length is computed from the swings the server itself just recorded,
--     not asked for by the client. There is no "give me more time" call to
--     abuse: the only way to buy a second is to make the server play a longer
--     fight, and the only way to do that is to actually have one.
--
--  3. It is capped. Nothing in the roster today can produce more than eight
--     swings, but abilities are coming, and a future one that swings fifty
--     times should not hand its owner a minute to think in. Twelve seconds is
--     comfortably more than the longest fight that can happen now.
--
--  cn_cine_ms is mirrored in the client as cineMs() in src/lib/cine.ts. The
--  two have to agree: the server is buying time for a picture the client is
--  drawing, and if the client's picture is longer than the server's budget the
--  player loses their turn watching it. If you change a beat length, change it
--  in both places.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. how long the fight takes to watch
--
-- One entry per kind of beat, plus a lead-in for the two of them squaring up
-- and a hold at the end so the last number is readable before the board comes
-- back. A beat that the client does not draw must not be counted here, and a
-- beat it draws must be.
-- ---------------------------------------------------------------------------
create or replace function public.cn_cine_ms(p_swings jsonb)
returns int language sql immutable as $$
  select least(12000, 900 + 700 + coalesce((
    select sum(case s->>'k'
                 when 'hit'   then 700
                 when 'heal'  then 700
                 when 'parry' then 600
                 when 'burn'  then 450
                 when 'down'  then 800
                 else 0 end)
      from jsonb_array_elements(
             case when jsonb_typeof(p_swings) = 'array'
                  then p_swings else '[]'::jsonb end) s), 0))::int
$$;
grant execute on function public.cn_cine_ms(jsonb) to authenticated, anon;

-- ---------------------------------------------------------------------------
-- 2. and the clock is pushed by it
--
-- Spliced from the existing definition rather than rewritten: everything above
-- the cn_attack call is the authorisation, and it is the only thing standing
-- between a client and somebody else's turn.
-- ---------------------------------------------------------------------------
create or replace function public.submit_attack(p_match uuid, p_unit text, p_target text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare m public.matches; v_side text;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.state->>'turn' <> v_side then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then raise exception 'your time ran out'; end if;

  m := cn_attack(p_match, v_side, p_unit, p_target);

  -- A finished match has no deadline to push -- cn_attack nulls it on the
  -- winning blow -- and there is no turn left to spend either.
  if m.status = 'active' and m.turn_deadline is not null then
    update public.matches
       set turn_deadline = turn_deadline
             + (cn_cine_ms(m.state->'fx'->'swings') || ' milliseconds')::interval
     where id = m.id
     returning * into m;
  end if;
  return m;
end $$;

-- ---------------------------------------------------------------------------
--  the checks
-- ---------------------------------------------------------------------------
select
  (select public.cn_cine_ms('[]'::jsonb) = 1600)                  as empty_is_the_frame,
  (select public.cn_cine_ms(null) = 1600)                         as null_is_too,
  (select public.cn_cine_ms('[{"k":"hit"},{"k":"hit"}]'::jsonb)
          = 1600 + 700 + 700)                                     as two_blows_add_up,
  (select public.cn_cine_ms(
            (select jsonb_agg(jsonb_build_object('k','down'))
               from generate_series(1, 40))) = 12000)             as and_it_is_capped,
  (select prosecdef from pg_proc where proname = 'submit_attack')  as still_definer;
