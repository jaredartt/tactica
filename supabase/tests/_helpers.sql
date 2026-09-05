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
create or replace function t_park(p_m uuid, p_ids text[]) returns void
language plpgsql as $$
declare i int := 0; u text;
begin
  foreach u in array p_ids loop
    i := i + 1;
    perform t_place(p_m, u, i - 1, case when left(u,1) = 'h' then 5 else 0 end);
  end loop;
end $$;
