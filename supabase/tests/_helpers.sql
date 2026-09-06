-- Assertions and board-rigging, shared by every test file. Loaded by run.sh
-- after the stub and before the tests.
create or replace function t_ok(cond boolean, label text) returns void
language plpgsql as $$
begin
  if cond then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %', label; end if;
end $$;

-- Expect the next statement to raise, and to mention `frag`.
create or replace function t_raises(sql text, frag text, label text) returns void
language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if position(lower(frag) in lower(SQLERRM)) > 0 then
      raise notice 'PASS  % (blocked: %)', label, SQLERRM;
      return;
    else
      raise exception 'FAIL  % — wrong error: %', label, SQLERRM;
    end if;
  end;
  raise exception 'FAIL  % — was allowed but should not be', label;
end $$;

-- RLS blocks an UPDATE by making the rows invisible rather than by raising,
-- so "was refused" here means "changed nothing".
create or replace function t_norows(sql text, label text) returns void
language plpgsql as $$
declare n int;
begin
  execute sql;
  get diagnostics n = row_count;
  if n = 0 then raise notice 'PASS  % (0 rows changed)', label;
  else raise exception 'FAIL  % — % row(s) changed', label, n; end if;
end $$;

-- ---------------------------------------------------------------------------
-- Rigging. These write the board directly, which no client can do -- that is
-- the point: a test needs a known position, not a random one.
-- ---------------------------------------------------------------------------
create or replace function t_set(p_m uuid, p_u text, p_key text, p_val jsonb)
returns void language sql as $$
  update public.matches set state = jsonb_set(state, '{units}', (
    select jsonb_agg(case when u->>'id' = p_u then jsonb_set(u, array[p_key], p_val) else u end)
      from jsonb_array_elements(state->'units') u)) where id = p_m;
$$;

create or replace function t_place(p_m uuid, p_u text, p_x int, p_y int)
returns void language sql as $$
  select t_set(p_m, p_u, 'x', to_jsonb(p_x)), t_set(p_m, p_u, 'y', to_jsonb(p_y));
$$;

create or replace function t_get(p_m uuid, p_u text, p_key text)
returns text language sql stable as $$
  select u->>p_key from public.matches m, jsonb_array_elements(m.state->'units') u
   where m.id = p_m and u->>'id' = p_u;
$$;

create or replace function t_alive(p_m uuid, p_u text) returns boolean
language sql stable as $$
  select exists (select 1 from public.matches m, jsonb_array_elements(m.state->'units') u
                  where m.id = p_m and u->>'id' = p_u);
$$;

create or replace function t_fx(p_m uuid, p_key text) returns text
language sql stable as $$ select state->'fx'->>p_key from public.matches where id = p_m $$;

create or replace function t_trees(p_m uuid, p_trees jsonb) returns void
language sql as $$
  update public.matches set state = jsonb_set(state, '{obstacles}', p_trees) where id = p_m;
$$;

create or replace function t_tree_hp(p_m uuid, p_t text) returns int
language sql stable as $$
  select (o->>'hp')::int from public.matches m, jsonb_array_elements(m.state->'obstacles') o
   where m.id = p_m and o->>'id' = p_t;
$$;

-- Give a unit a fixed profile so a test can assert an exact number instead of
-- a band. Everything else about it -- reach, counter reach, burn -- is left
-- alone, because that is usually what is under test.
create or replace function t_dmg(p_m uuid, p_u text, p_d int) returns void
language sql as $$
  select t_set(p_m, p_u, 'dmin', to_jsonb(p_d)), t_set(p_m, p_u, 'dmax', to_jsonb(p_d));
$$;

create or replace function t_hp(p_m uuid, p_u text, p_hp int) returns void
language sql as $$ select t_set(p_m, p_u, 'hp', to_jsonb(p_hp)); $$;

-- Open a room, seat both players, deploy nothing, start the match.
create or replace function t_match(p_host uuid, p_guest uuid, out mid uuid)
language plpgsql as $$
declare c text;
begin
  perform set_config('app.uid', p_host::text, false);
  select id, code into mid, c from public.create_match();
  perform set_config('app.uid', p_guest::text, false);
  perform public.join_match(c);
  perform public.set_ready(mid);
  perform set_config('app.uid', p_host::text, false);
  perform public.set_ready(mid);
end $$;

-- Clear every unit's move/attack flags without ending the turn, so one test
-- match can play out a dozen separate exchanges.
create or replace function t_reset(p_m uuid) returns void
language sql as $$
  update public.matches set state = jsonb_set(state, '{units}', (
    select jsonb_agg(jsonb_set(jsonb_set(u, '{moved}', 'false'), '{acted}', 'false'))
      from jsonb_array_elements(state->'units') u))
   where id = p_m;
$$;

-- Park an army out of the way so a test can reason about two units alone.
-- Each side goes down its own back column: the two columns are five apart on
-- a six-wide board, which is further than anything can reach. Counting per
-- side and not across the whole list matters -- a single counter walked the
-- guests off the right-hand edge, where nothing could ever be attacked and a
-- test would silently assert about a unit standing outside the board.
create or replace function t_park(p_m uuid, p_ids text[]) returns void
language plpgsql as $$
declare hi int := 0; gi int := 0; u text; v_w int;
begin
  select (state->'board'->>'w')::int into v_w from public.matches where id = p_m;
  foreach u in array p_ids loop
    if left(u, 1) = 'h'
      then perform t_place(p_m, u, 0, hi);         hi := hi + 1;
      else perform t_place(p_m, u, v_w - 1, gi);   gi := gi + 1;
    end if;
  end loop;
end $$;

-- Back to full health, whatever card it happens to be. A test that grinds a
-- unit down over several assertions and then asserts "it took damage" reads
-- as flaky when what actually happened is that the unit died three lines ago.
create or replace function t_full(p_m uuid, p_u text) returns void
language sql as $$
  select t_set(p_m, p_u, 'hp',
               (select u->'maxHp' from public.matches m, jsonb_array_elements(m.state->'units') u
                 where m.id = p_m and u->>'id' = p_u));
$$;

-- ---------------------------------------------------------------------------
-- During deployment the two armies are not in the match row at all -- that is
-- the point of it -- so reading and rigging them needs its own set.
-- ---------------------------------------------------------------------------
create or replace function t_dep(p_m uuid, p_side text) returns jsonb
language sql stable as $$
  select units from public.match_deploy where match_id = p_m and side = p_side;
$$;

create or replace function t_dcount(p_m uuid, p_side text) returns int
language sql stable as $$ select jsonb_array_length(t_dep(p_m, p_side)) $$;

create or replace function t_dget(p_m uuid, p_side text, p_u text, p_key text) returns text
language sql stable as $$
  select u->>p_key from public.match_deploy d, jsonb_array_elements(d.units) u
   where d.match_id = p_m and d.side = p_side and u->>'id' = p_u;
$$;

create or replace function t_dplace(p_m uuid, p_side text, p_u text, p_x int, p_y int)
returns void language sql as $$
  update public.match_deploy set units = (
    select jsonb_agg(case when u->>'id' = p_u
             then jsonb_set(jsonb_set(u, '{x}', to_jsonb(p_x)), '{y}', to_jsonb(p_y))
             else u end)
      from jsonb_array_elements(units) u)
   where match_id = p_m and side = p_side;
$$;
