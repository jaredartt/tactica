-- ---------------------------------------------------------------------------
-- 0017  who opens is a coin flip, in every mode
--
-- Spliced from 0008 rather than written fresh: cn_set_ready is the function
-- that turns two hidden half-boards into one live game, and rewriting it from
-- memory is how deploy_unit quietly lost its swap behaviour back in 0011. The
-- only change is the block marked inside.
-- ---------------------------------------------------------------------------

create or replace function public.cn_set_ready(p_match uuid, p_side text, p_force boolean)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare m public.matches; v_st jsonb; v_host jsonb; v_guest jsonb; v_first text;
begin
  select * into m from public.matches where id = p_match for update;
  if m.status <> 'deploying' then return m; end if;

  v_st := m.state;
  if p_force then
    v_st := jsonb_set(v_st, '{ready}', jsonb_build_object('host', true, 'guest', true));
    v_st := state_log(v_st, 'Deployment time ran out.');
  else
    v_st := jsonb_set(v_st, array['ready', p_side], 'true'::jsonb);
    v_st := state_log(v_st,
      case when p_side = 'host' then m.host_name else m.guest_name end || ' is ready.');
  end if;

  if not ((v_st->'ready'->>'host')::boolean and (v_st->'ready'->>'guest')::boolean) then
    update public.matches set state = v_st, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  -- Both ready: this is the first moment either of you may see the other, so
  -- this is where the two halves become one board.
  select units into v_host  from public.match_deploy where match_id = p_match and side = 'host';
  select units into v_guest from public.match_deploy where match_id = p_match and side = 'guest';
  if v_host is not null and v_guest is not null then
    v_st := jsonb_set(v_st, '{units}', v_host || v_guest);
  end if;

  -- Who opens is a coin, not a seat. Before this the host moved first in every
  -- mode -- and the host is whoever pressed the button: the human in practice,
  -- the one who made the room among friends. Ranked already flipped a coin for
  -- the SEAT (0012), which sorted ranked and nothing else. Flipping here sorts
  -- all of them at once, because every mode arrives at this line, and it flips
  -- at the start of the battle rather than at creation so deployment is
  -- untouched.
  --
  -- cn.first_side is the tests' way in. A suite that cannot predict who acts
  -- first fails one run in two, and neither a random test nor a rigged game is
  -- worth having.
  v_first := nullif(current_setting('cn.first_side', true), '');
  if v_first is null or v_first not in ('host', 'guest') then
    v_first := case when random() < 0.5 then 'host' else 'guest' end;
  end if;

  v_st := jsonb_set(v_st, '{phase}', '"battle"'::jsonb);
  v_st := jsonb_set(v_st, '{turn}', to_jsonb(v_first));
  v_st := jsonb_set(v_st, '{turnNumber}', '1'::jsonb);
  v_st := state_log(v_st, 'Turn 1 — ' ||
    case when v_first = 'host' then m.host_name else m.guest_name end || ' to act.');

  update public.matches
     set state = v_st, status = 'active',
         turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

-- ---------------------------------------------------------------------------
-- Did it work? Both true means yes.
-- ---------------------------------------------------------------------------
select
  to_regprocedure('public.cn_set_ready(uuid, text, boolean)') is not null as set_ready_ready,
  position('cn.first_side' in pg_get_functiondef(
    'public.cn_set_ready(uuid, text, boolean)'::regprocedure)) > 0 as coin_flip_installed;
