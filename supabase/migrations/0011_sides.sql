-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0010 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0011 — the board turns ninety degrees
--
--  Until now each player held the near half of the board and the guest's
--  screen showed the whole thing rotated, so that "your ground" was always at
--  the bottom. It works, but it means the two people in a match are never
--  looking at the same picture: a square the host calls top-left the guest
--  calls bottom-right, and neither can say "the tree next to your archer"
--  without both of them re-deriving it.
--
--  So: the halves become left and right, and nothing is rotated. The host
--  holds the left, the guest holds the right, and both players -- and anybody
--  watching -- see one board with the same square in the same place. Which
--  units are yours is carried by colour instead of by position, which is what
--  colour was already doing everywhere else in the app.
--
--  Left is blue and right is red, the two ends of the logo.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. whose ground is that column
--
-- Dropped rather than replaced: the arguments now mean x and w where they
-- used to mean y and h, and Postgres will not let a replacement rename an
-- input parameter. A function whose parameter is called p_y while holding an
-- x is worse than a drop.
-- ---------------------------------------------------------------------------
drop function if exists public.cn_own_half(text, int, int);

create or replace function public.cn_own_side(p_side text, p_x int, p_w int)
returns boolean language sql immutable as $$
  select case when p_side = 'host' then p_x < p_w / 2 else p_x >= p_w / 2 end
$$;
grant execute on function public.cn_own_side(text, int, int) to authenticated, anon;

-- ---------------------------------------------------------------------------
-- 2. deployment checks the column
-- ---------------------------------------------------------------------------
create or replace function public.deploy_unit(p_match uuid, p_unit text, p_x int, p_y int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; v_side text; v_st jsonb; v_units jsonb; u jsonb; e jsonb;
  v_me jsonb; v_swap jsonb; v_out jsonb := '[]'::jsonb; v_w int; v_h int;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'deploying' then raise exception 'deployment is over'; end if;

  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if (m.state->'ready'->>v_side)::boolean then raise exception 'you are already ready'; end if;

  v_st := m.state;
  v_w := (v_st->'board'->>'w')::int;
  v_h := (v_st->'board'->>'h')::int;

  select units into v_units from public.match_deploy
   where match_id = p_match and side = v_side for update;
  if v_units is null then raise exception 'nothing to deploy'; end if;

  for u in select * from jsonb_array_elements(v_units) loop
    if u->>'id' = p_unit then v_me := u; end if;
    if (u->>'x')::int = p_x and (u->>'y')::int = p_y then v_swap := u; end if;
  end loop;
  if v_me is null then raise exception 'that is not your unit'; end if;

  if p_x < 0 or p_y < 0 or p_x >= v_w or p_y >= v_h then raise exception 'off the board'; end if;
  if not cn_own_side(v_side, p_x, v_w) then raise exception 'that is not your half'; end if;

  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if (e->>'x')::int = p_x and (e->>'y')::int = p_y then
      raise exception 'there is a tree there';
    end if;
  end loop;

  -- Landing on one of your own is a swap, not an error: it is the fastest way
  -- to say "these two the other way round". The other army is not in this
  -- array at all, so there is nothing else it could collide with.
  for u in select * from jsonb_array_elements(v_units) loop
    if u->>'id' = p_unit then
      u := jsonb_set(jsonb_set(u, '{x}', to_jsonb(p_x)), '{y}', to_jsonb(p_y));
    elsif v_swap is not null and u->>'id' = v_swap->>'id' then
      u := jsonb_set(jsonb_set(u, '{x}', v_me->'x'), '{y}', v_me->'y');
    end if;
    v_out := v_out || u;
  end loop;

  update public.match_deploy set units = v_out
   where match_id = p_match and side = v_side;
  update public.matches set updated_at = now() where id = p_match;
  return v_out;
end $$;
grant execute on function public.deploy_unit(uuid, text, int, int) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. the opening formation
--
-- Same idea as before, one axis over: fill the back column first and spread
-- along it, so the two armies start facing each other across the middle
-- instead of stacked in a corner. The host's back column is 0, the guest's
-- is w-1.
-- ---------------------------------------------------------------------------
create or replace function public.cn_army(p_state jsonb, p_side text, p_deck text[])
returns jsonb language plpgsql as $$
declare
  v_w int := (p_state->'board'->>'w')::int;
  v_h int := (p_state->'board'->>'h')::int;
  v_taken text[] := '{}'; e jsonb; c public.cards;
  v_xs int[] := '{}'::int[]; v_ys int[] := '{}'::int[];
  i int; vx int; vy int; v_idx int := 0;
  v_units jsonb := '[]'::jsonb; v_done boolean;
begin
  for e in select * from jsonb_array_elements(coalesce(p_state->'obstacles', '[]'::jsonb)) loop
    v_taken := v_taken || ((e->>'x') || ',' || (e->>'y'));
  end loop;

  -- rows, odd ones first, so four units on a six-row board are not adjacent
  for i in 0 .. (v_h - 1) / 2 loop
    if 2 * i + 1 < v_h then v_ys := v_ys || (2 * i + 1); end if;
  end loop;
  for i in 0 .. (v_h - 1) / 2 loop
    if 2 * i < v_h then v_ys := v_ys || (2 * i); end if;
  end loop;

  -- columns, back rank first
  if p_side = 'host'
    then for i in 0 .. (v_w / 2 - 1)            loop v_xs := v_xs || i; end loop;
    else for i in reverse (v_w - 1) .. (v_w / 2) loop v_xs := v_xs || i; end loop;
  end if;

  for i in 1 .. deck_size() loop
    select * into c from public.cards where slug = p_deck[i];
    if c.id is null then raise exception 'unknown card %', p_deck[i]; end if;

    v_done := false;
    foreach vx in array v_xs loop
      foreach vy in array v_ys loop
        if not ((vx || ',' || vy) = any(v_taken)) then
          v_taken := v_taken || (vx || ',' || vy);
          v_done := true;
          exit;
        end if;
      end loop;
      exit when v_done;
    end loop;
    if not v_done then raise exception 'nowhere to deploy'; end if;

    v_idx := v_idx + 1;
    v_units := v_units || jsonb_build_object(
      'id', substr(p_side, 1, 1) || v_idx, 'owner', p_side,
      'cardId', c.id, 'slug', c.slug, 'name', c.name, 'role', c.role,
      'hp', c.hp, 'maxHp', c.hp, 'mov', c.mov,
      'rmin', c.rmin, 'rmax', c.rmax, 'crmin', c.crmin, 'crmax', c.crmax,
      'dmin', c.dmin, 'dmax', c.dmax,
      'burns', c.burns, 'heals', c.heals, 'burned', false,
      'flies', c.flies, 'sneaks', c.sneaks, 'cures', c.cures, 'tramples', c.tramples,
      'accent', c.accent, 'art', c.art_url, 'ability', c.ability,
      'x', vx, 'y', vy, 'moved', false, 'acted', false);
  end loop;
  return v_units;
end $$;

-- ---------------------------------------------------------------------------
-- 4. the trees
--
-- Three per half as before; the halves are now columns. The two are still
-- rolled independently, so terrain is not mirrored.
-- ---------------------------------------------------------------------------
create or replace function public.cn_gen_trees(p_w int, p_h int)
returns jsonb language plpgsql as $$
declare
  v_try int; v_band int; v_lo int; v_hi int; v_n int;
  v_cand int[]; v_pick int[] := '{}'::int[]; v_ok boolean;
  i int; j int; v_x int; v_y int; v_px int; v_py int;
  v_out jsonb := '[]'::jsonb; v_k int := 0;
begin
  for v_try in 1..80 loop
    v_pick := '{}'::int[];
    for v_band in 0..1 loop
      if v_band = 0 then v_lo := 0; v_hi := p_w / 2 - 1;
                    else v_lo := p_w / 2; v_hi := p_w - 1; end if;

      select array_agg(t) into v_cand from (
        select gy.y * p_w + gx.x as t
          from generate_series(v_lo, v_hi) as gx(x),
               generate_series(0, p_h - 1) as gy(y)
         where not ((gx.x = 0 or gx.x = p_w - 1) and (gy.y = 0 or gy.y = p_h - 1))
         order by random()) s;

      v_n := 0;
      foreach i in array v_cand loop
        exit when v_n = 3;
        v_x := i % p_w; v_y := i / p_w;
        v_ok := true;
        foreach j in array v_pick loop
          v_px := j % p_w; v_py := j / p_w;
          if cn_cheb(v_x, v_y, v_px, v_py) < 2 then v_ok := false; exit; end if;
        end loop;
        if v_ok then v_pick := v_pick || i; v_n := v_n + 1; end if;
      end loop;
      exit when v_n < 3;
    end loop;
    exit when coalesce(array_length(v_pick, 1), 0) = 6;
  end loop;

  -- Eighty shuffled goes is plenty, but a greedy pass can in principle paint
  -- itself into a corner. If every one failed, use a layout known to satisfy
  -- the rules rather than opening a room with no trees in it: one tree per
  -- half-column, staggered down the rows.
  if coalesce(array_length(v_pick, 1), 0) <> 6 then
    v_pick := array[ 1 * p_w + 0, 3 * p_w + 1, 5 * p_w % (p_w * p_h) + 2,
                     0 * p_w + (p_w - 1), 2 * p_w + (p_w - 2), 4 * p_w + (p_w - 3) ];
  end if;

  foreach i in array v_pick loop
    v_k := v_k + 1;
    v_out := v_out || jsonb_build_object(
      'id', 't' || v_k, 'x', i % p_w, 'y', i / p_w, 'hp', 30, 'maxHp', 30);
  end loop;
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
with a as (select public.cn_army(public.cn_fresh_map(), 'host',  public.default_deck()) as u),
     b as (select public.cn_army(public.cn_fresh_map(), 'guest', public.default_deck()) as u),
     t as (select public.cn_gen_trees(6, 6) as o)
select
  public.cn_own_side('host',  0, 6) and not public.cn_own_side('host',  3, 6)
                                                                     as host_holds_the_left,
  public.cn_own_side('guest', 5, 6) and not public.cn_own_side('guest', 2, 6)
                                                                     as guest_holds_the_right,
  (select bool_and((e->>'x')::int < 3) from a, jsonb_array_elements(a.u) e)
                                                                     as host_starts_left,
  (select bool_and((e->>'x')::int >= 3) from b, jsonb_array_elements(b.u) e)
                                                                     as guest_starts_right,
  (select count(*) = 3 from t, jsonb_array_elements(t.o) e where (e->>'x')::int < 3)
                                                                     as three_trees_each_side,
  (select jsonb_array_length(o) = 6 from t)                          as six_trees_in_all;
