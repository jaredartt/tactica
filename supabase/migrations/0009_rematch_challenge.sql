-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  The last statement prints a row of checks. Every column must say true.
-- ===========================================================================
--  0009 — a rematch is an invitation, so it can be turned down
--
--  Asking already worked: both flags set and the room appears. What was
--  missing was the other half of a conversation. Someone who does not want
--  another game had no way to say so, and the person who asked sat on
--  "Waiting for them" until they gave up and left.
--
--  One column and one function. Declining clears both flags -- so the asker's
--  button comes back rather than staying stuck -- and leaves a mark that says
--  why nothing happened. Asking again clears that mark, so a "not now" never
--  becomes a permanent no.
-- ===========================================================================

alter table public.matches add column if not exists rematch_declined boolean not null default false;

create or replace function public.decline_rematch(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare m public.matches; v_side text;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.next_match_id is not null then return m; end if;   -- too late, it started

  update public.matches
     set rematch_host = false, rematch_guest = false,
         rematch_declined = true, updated_at = now()
   where id = p_match returning * into m;
  return m;
end $$;

-- Same as before, except that asking wipes the "not today" -- otherwise the
-- note would still be sitting there under a fresh invitation.
create or replace function public.request_rematch(p_match uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare m public.matches; v_side text; v_st jsonb; nm public.matches; v_new uuid;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'finished' then raise exception 'that match is still running'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.next_match_id is not null then return m.next_match_id; end if;

  if m.bot is not null then
    select id into v_new from public.create_bot_match(m.bot);
    update public.matches set next_match_id = v_new where id = p_match;
    return v_new;
  end if;

  if v_side = 'host'
    then update public.matches set rematch_host  = true, rematch_declined = false where id = p_match;
    else update public.matches set rematch_guest = true, rematch_declined = false where id = p_match;
  end if;

  select * into m from public.matches where id = p_match;
  if not (m.rematch_host and m.rematch_guest) then return null; end if;

  -- Sides swap, so nobody keeps the first-move advantage two games running.
  v_st := cn_fresh_map();
  v_st := state_log(v_st, 'Rematch on new ground. ' || m.guest_name || ' moves first.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline, ranked)
  values
    (gen_match_code(), m.guest_id, m.guest_name, m.host_id, m.host_name,
     'deploying', v_st, now() + interval '90 seconds', false)
  returning * into nm;

  perform cn_open_deploy(nm.id, nm.state, nm.host_id, nm.guest_id, null);
  insert into public.match_presence (match_id, user_id, side) values
    (nm.id, nm.host_id, 'host'), (nm.id, nm.guest_id, 'guest')
  on conflict (match_id, user_id) do update set seen_at = now();

  update public.matches set next_match_id = nm.id where id = p_match;
  return nm.id;
end $$;

grant execute on function public.decline_rematch(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  to_regprocedure('public.decline_rematch(uuid)') is not null as decline_created,
  exists (select 1 from information_schema.columns
           where table_name = 'matches' and column_name = 'rematch_declined') as column_added;
