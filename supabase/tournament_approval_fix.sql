-- Turnier der Kraft: Freigabe getrennt von status.
-- status bleibt active/cancelled (tournament_signups_status_check) und wird
-- von submit_tournament_signup, cancel_tournament_signup und
-- list_tournament_signups benutzt. Diese Datei ändert diese Funktionen,
-- die Spalte status und die bestehende Check-Constraint nicht.
--
-- Neu: approval text not null default 'pending'
-- mit Check pending/approved/rejected.
-- Bestehende Zeilen werden dadurch pending. Ein erneuter Lauf setzt
-- bereits gesetzte Freigaben nicht zurück.
-- Abgemeldete Zeilen (status = cancelled) zählen nirgends: nicht in der
-- Freigabeliste, nicht in der Sichtbarkeit, nicht in der Auslosung.
--
-- Einmal im SQL-Editor ausführen, nachdem supabase/tournament_bracket.sql
-- gelaufen ist. Die Datei darf erneut laufen.

do $$
begin
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'public.is_admin() fehlt.';
  end if;
  if to_regclass('public.tournament_signups') is null then
    raise exception 'public.tournament_signups fehlt.';
  end if;
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'tournament_signups'
      and column_name = 'status'
  ) then
    raise exception 'public.tournament_signups.status fehlt.';
  end if;
end $$;

alter table public.tournament_signups
  add column if not exists approval text not null default 'pending';

update public.tournament_signups
set approval = 'pending'
where approval is null;

alter table public.tournament_signups
  alter column approval set default 'pending';

alter table public.tournament_signups
  alter column approval set not null;

alter table public.tournament_signups
  drop constraint if exists tournament_signups_approval_check;

alter table public.tournament_signups
  add constraint tournament_signups_approval_check
  check (approval in ('pending', 'approved', 'rejected'));

comment on column public.tournament_signups.approval is
  'Admin-Freigabe: pending, approved oder rejected. Unabhängig von status (active/cancelled).';

-- Argumentname bleibt p_status, weil PostgreSQL den Namen bei create or replace
-- nicht ändert. Der Wert ist die Spalte approval, nicht status.
create or replace function public.tournament_signup_state(p_status text)
returns text
language sql
immutable
as $$
  select case lower(btrim(coalesce(p_status, '')))
    when 'approved' then 'approved'
    when 'rejected' then 'rejected'
    else 'pending'
  end;
$$;

create or replace function public.can_view_tournament_board()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin()
    or exists (
      select 1
      from public.tournament_signups s
      where s.user_id = auth.uid()
        and s.status is distinct from 'cancelled'
        and public.tournament_signup_state(s.approval) <> 'rejected'
    );
$$;

create or replace function public.save_tournament_board(p_board jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mode text;
  v_existing uuid;
  v_existing_mode text;
  v_approved int;
  v_entry_count int;
  v_match_count int;
  v_names jsonb;
  v_draw uuid;
  v_groups jsonb := '{}'::jsonb;
  v_entries jsonb := '{}'::jsonb;
  v_matches jsonb := '{}'::jsonb;
  r record;
  v_ref text;
  v_signup uuid;
  v_group_ref text;
  v_group_id uuid;
  v_tiebreak int;
  v_info jsonb;
  v_entry_id uuid;
  v_match_id uuid;
  v_player_a uuid;
  v_player_b uuid;
  v_winner uuid;
  v_feeds uuid;
  v_source_a uuid;
  v_source_b uuid;
  v_limit constant int := 32;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Nur ein Administrator kann die Auslosung speichern.';
  end if;
  if p_board is null or jsonb_typeof(p_board) <> 'object'
     or jsonb_typeof(p_board->'entries') <> 'array'
     or jsonb_typeof(p_board->'matches') <> 'array' then
    raise exception 'Die Auslosung ist unvollständig.';
  end if;

  perform pg_advisory_xact_lock(4815162342);

  v_mode := p_board->>'mode';
  if v_mode not in ('ko', 'groups') then
    raise exception 'Unbekannter Modus.';
  end if;

  select count(*) into v_entry_count from jsonb_array_elements(p_board->'entries');
  select count(*) into v_match_count from jsonb_array_elements(p_board->'matches');
  if v_entry_count < 2 or v_entry_count > 256 or v_match_count < 1 or v_match_count > 2000 then
    raise exception 'Die Auslosung hat eine ungültige Größe.';
  end if;
  if v_mode = 'ko' and jsonb_array_length(coalesce(p_board->'groups', '[]'::jsonb)) <> 0 then
    raise exception 'Die direkte K.-o.-Runde hat keine Gruppen.';
  end if;
  if v_mode = 'groups' and jsonb_array_length(coalesce(p_board->'groups', '[]'::jsonb)) < 1 then
    raise exception 'Die Gruppen fehlen.';
  end if;

  select id, mode into v_existing, v_existing_mode
  from public.tournament_draws
  order by created_at desc
  limit 1;

  if v_existing is null then
    select count(*) into v_approved
    from public.tournament_signups s
    where s.status is distinct from 'cancelled' and public.tournament_signup_state(s.approval) = 'approved';
    if v_entry_count <> v_approved then
      raise exception 'Die Auslosung muss genau die freigegebenen Anmeldungen enthalten.';
    end if;
    if v_approved <= v_limit and v_mode <> 'ko' then
      raise exception 'Bis 32 freigegebene Teilnehmer gibt es eine direkte K.-o.-Runde.';
    end if;
    if v_approved > v_limit and v_mode <> 'groups' then
      raise exception 'Ab 33 freigegebenen Teilnehmern gibt es zuerst Gruppen.';
    end if;
    if exists (
      select 1
      from jsonb_array_elements(p_board->'entries') value
      where not exists (
        select 1
        from public.tournament_signups s
        where s.id = (value->>'signupId')::uuid
          and s.status is distinct from 'cancelled' and public.tournament_signup_state(s.approval) = 'approved'
      )
    ) then
      raise exception 'Nur freigegebene Anmeldungen kommen in die Auslosung.';
    end if;
    select coalesce(jsonb_object_agg(s.id::text, jsonb_build_object(
      'name', btrim(s.character_name),
      'class', btrim(s."class"),
      'faction', lower(btrim(s.faction))
    )), '{}'::jsonb)
    into v_names
    from public.tournament_signups s
    where s.status is distinct from 'cancelled' and public.tournament_signup_state(s.approval) = 'approved';
  else
    if v_existing_mode is distinct from v_mode then
      raise exception 'Der Modus einer laufenden Auslosung bleibt gleich.';
    end if;
    if exists (
      select 1
      from (
        select (value->>'signupId')::uuid as id
        from jsonb_array_elements(p_board->'entries') value
      ) incoming
      full outer join (
        select signup_id as id
        from public.tournament_entries
        where draw_id = v_existing
      ) stored on stored.id = incoming.id
      where incoming.id is null or stored.id is null
    ) then
      raise exception 'Die Teilnehmer bleiben die der Auslosung. Zum Ändern zuerst zurücksetzen.';
    end if;
    select coalesce(jsonb_object_agg(e.signup_id::text, jsonb_build_object(
      'name', e.character_name,
      'class', e.class_name,
      'faction', e.faction
    )), '{}'::jsonb)
    into v_names
    from public.tournament_entries e
    where e.draw_id = v_existing;
  end if;

  if (
    select count(distinct value->>'ref')
    from jsonb_array_elements(p_board->'entries') value
  ) <> v_entry_count then
    raise exception 'Eine Anmeldung kommt doppelt vor.';
  end if;
  if (
    select count(distinct value->>'signupId')
    from jsonb_array_elements(p_board->'entries') value
  ) <> v_entry_count then
    raise exception 'Eine Anmeldung kommt doppelt vor.';
  end if;

  delete from public.tournament_draws;

  insert into public.tournament_draws (mode, created_by)
  values (v_mode, auth.uid())
  returning id into v_draw;

  for r in select value as item from jsonb_array_elements(coalesce(p_board->'groups', '[]'::jsonb))
  loop
    v_ref := btrim(coalesce(r.item->>'ref', ''));
    if v_ref = '' or char_length(v_ref) > 80 or jsonb_exists(v_groups, v_ref) then
      raise exception 'Eine Gruppe ist ungültig.';
    end if;
    if char_length(btrim(coalesce(r.item->>'label', ''))) < 1 then
      raise exception 'Eine Gruppe ist ungültig.';
    end if;
    insert into public.tournament_groups (draw_id, label, sort_order)
    values (
      v_draw,
      btrim(coalesce(r.item->>'label', '')),
      coalesce((r.item->>'sort')::int, 0)
    )
    returning id into v_group_id;
    v_groups := v_groups || jsonb_build_object(v_ref, v_group_id::text);
  end loop;

  for r in select value as item from jsonb_array_elements(p_board->'entries')
  loop
    v_ref := btrim(coalesce(r.item->>'ref', ''));
    v_signup := (r.item->>'signupId')::uuid;
    v_info := v_names->v_signup::text;
    if v_ref = '' or jsonb_exists(v_entries, v_ref) or v_info is null then
      raise exception 'Ein Teilnehmer der Auslosung fehlt.';
    end if;
    if coalesce(v_info->>'faction', '') not in ('horde', 'alliance')
       or char_length(coalesce(v_info->>'name', '')) < 1
       or char_length(coalesce(v_info->>'class', '')) < 1 then
      raise exception 'Ein Teilnehmer hat unvollständige Angaben.';
    end if;
    v_group_ref := nullif(btrim(coalesce(r.item->>'groupRef', '')), '');
    v_group_id := null;
    if v_group_ref is not null then
      if not jsonb_exists(v_groups, v_group_ref) then
        raise exception 'Eine Gruppe fehlt.';
      end if;
      v_group_id := (v_groups->>v_group_ref)::uuid;
    end if;
    v_tiebreak := coalesce((r.item->>'tiebreak')::int, 0);
    insert into public.tournament_entries (
      draw_id, group_id, signup_id, character_name, class_name, faction, tiebreak
    ) values (
      v_draw, v_group_id, v_signup, v_info->>'name', v_info->>'class', v_info->>'faction', v_tiebreak
    )
    returning id into v_entry_id;
    v_entries := v_entries || jsonb_build_object(v_ref, v_entry_id::text);
  end loop;

  for r in select value as item from jsonb_array_elements(p_board->'matches')
  loop
    v_ref := btrim(coalesce(r.item->>'ref', ''));
    if v_ref = '' or char_length(v_ref) > 80 or jsonb_exists(v_matches, v_ref) then
      raise exception 'Ein Spiel ist ungültig.';
    end if;
    if coalesce(r.item->>'stage', '') not in ('group', 'ko') then
      raise exception 'Ein Spiel ist ungültig.';
    end if;
    if nullif(r.item->>'byeSide', '') is not null and r.item->>'byeSide' not in ('a', 'b') then
      raise exception 'Ein Spiel ist ungültig.';
    end if;
    if nullif(r.item->>'feedsSlot', '') is not null and r.item->>'feedsSlot' not in ('a', 'b') then
      raise exception 'Ein Spiel verweist ins Leere.';
    end if;
    v_group_ref := nullif(btrim(coalesce(r.item->>'groupRef', '')), '');
    v_group_id := null;
    if v_group_ref is not null then
      if not jsonb_exists(v_groups, v_group_ref) then
        raise exception 'Eine Gruppe fehlt.';
      end if;
      v_group_id := (v_groups->>v_group_ref)::uuid;
    end if;
    v_player_a := null;
    v_player_b := null;
    v_winner := null;
    if nullif(btrim(coalesce(r.item->>'a', '')), '') is not null then
      if not jsonb_exists(v_entries, r.item->>'a') then
        raise exception 'Ein Spiel verweist auf einen unbekannten Teilnehmer.';
      end if;
      v_player_a := (v_entries->>(r.item->>'a'))::uuid;
    end if;
    if nullif(btrim(coalesce(r.item->>'b', '')), '') is not null then
      if not jsonb_exists(v_entries, r.item->>'b') then
        raise exception 'Ein Spiel verweist auf einen unbekannten Teilnehmer.';
      end if;
      v_player_b := (v_entries->>(r.item->>'b'))::uuid;
    end if;
    if nullif(btrim(coalesce(r.item->>'winner', '')), '') is not null then
      if not jsonb_exists(v_entries, r.item->>'winner') then
        raise exception 'Der Sieger gehört nicht ins Turnier.';
      end if;
      v_winner := (v_entries->>(r.item->>'winner'))::uuid;
      if v_winner is distinct from v_player_a and v_winner is distinct from v_player_b then
        raise exception 'Der Sieger muss einer der beiden Spieler sein.';
      end if;
    end if;
    v_source_a := null;
    v_source_b := null;
    if jsonb_typeof(r.item->'sourceA') = 'object' then
      v_group_ref := r.item#>>'{sourceA,groupRef}';
      if v_group_ref is null or not jsonb_exists(v_groups, v_group_ref) then
        raise exception 'Eine Gruppe fehlt.';
      end if;
      v_source_a := (v_groups->>v_group_ref)::uuid;
    end if;
    if jsonb_typeof(r.item->'sourceB') = 'object' then
      v_group_ref := r.item#>>'{sourceB,groupRef}';
      if v_group_ref is null or not jsonb_exists(v_groups, v_group_ref) then
        raise exception 'Eine Gruppe fehlt.';
      end if;
      v_source_b := (v_groups->>v_group_ref)::uuid;
    end if;
    insert into public.tournament_matches (
      draw_id, stage, group_id, round_no, slot_no,
      player_a, player_b, winner_id, is_bye, bye_side,
      placeholder_a, placeholder_b,
      source_a_group, source_a_place, source_b_group, source_b_place,
      feeds_slot
    ) values (
      v_draw,
      r.item->>'stage',
      v_group_id,
      (r.item->>'round')::int,
      (r.item->>'slot')::int,
      v_player_a,
      v_player_b,
      v_winner,
      coalesce((r.item->>'bye')::boolean, false),
      nullif(r.item->>'byeSide', ''),
      nullif(btrim(coalesce(r.item->>'placeholderA', '')), ''),
      nullif(btrim(coalesce(r.item->>'placeholderB', '')), ''),
      v_source_a,
      case when v_source_a is null then null else (r.item#>>'{sourceA,place}')::int end,
      v_source_b,
      case when v_source_b is null then null else (r.item#>>'{sourceB,place}')::int end,
      nullif(r.item->>'feedsSlot', '')
    )
    returning id into v_match_id;
    v_matches := v_matches || jsonb_build_object(v_ref, v_match_id::text);
  end loop;

  for r in select value as item from jsonb_array_elements(p_board->'matches')
  loop
    if nullif(btrim(coalesce(r.item->>'feeds', '')), '') is null then
      continue;
    end if;
    if not jsonb_exists(v_matches, r.item->>'ref') or not jsonb_exists(v_matches, r.item->>'feeds') then
      raise exception 'Ein Spiel verweist ins Leere.';
    end if;
    if coalesce(r.item->>'feedsSlot', '') not in ('a', 'b') then
      raise exception 'Ein Spiel verweist ins Leere.';
    end if;
    v_match_id := (v_matches->>(r.item->>'ref'))::uuid;
    v_feeds := (v_matches->>(r.item->>'feeds'))::uuid;
    update public.tournament_matches
    set feeds_match = v_feeds,
        feeds_slot = r.item->>'feedsSlot'
    where id = v_match_id;
  end loop;

  return public.tournament_board();
exception
  when invalid_text_representation then
    raise exception 'Eine Kennung ist ungültig.';
end;
$$;


create or replace function public.admin_list_tournament_signups()
returns table (
  id uuid,
  created_at timestamptz,
  character_name text,
  class_name text,
  faction text,
  discord_name text,
  status text,
  state text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Nur ein Administrator sieht die Freigaben.';
  end if;
  return query
  select
    s.id,
    s.created_at,
    s.character_name,
    s."class",
    s.faction,
    s.discord_name,
    s.status,
    public.tournament_signup_state(s.approval)
  from public.tournament_signups s
  where s.status is distinct from 'cancelled'
  order by s.created_at, s.character_name;
end;
$$;

create or replace function public.set_tournament_signup_status(p_id uuid, p_action text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_value text;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Nur ein Administrator kann Anmeldungen freigeben.';
  end if;
  if p_id is null then
    raise exception 'Diese Anmeldung gibt es nicht.';
  end if;
  if p_action = 'approve' then
    v_value := 'approved';
  elsif p_action = 'reject' then
    v_value := 'rejected';
  else
    raise exception 'Unbekannte Aktion.';
  end if;

  update public.tournament_signups
  set approval = v_value
  where id = p_id
    and status is distinct from 'cancelled';

  if not found then
    if exists (
      select 1
      from public.tournament_signups
      where id = p_id
        and status = 'cancelled'
    ) then
      raise exception 'Abgemeldete Anmeldungen werden nicht freigegeben.';
    end if;
    raise exception 'Diese Anmeldung gibt es nicht.';
  end if;

  return public.tournament_signup_state(v_value);
end;
$$;

alter function public.can_view_tournament_board() set row_security = off;
alter function public.save_tournament_board(jsonb) set row_security = off;
alter function public.admin_list_tournament_signups() set row_security = off;
alter function public.set_tournament_signup_status(uuid, text) set row_security = off;

revoke all on function public.tournament_signup_state(text) from public;
revoke all on function public.can_view_tournament_board() from public;
revoke all on function public.save_tournament_board(jsonb) from public;
revoke all on function public.admin_list_tournament_signups() from public;
revoke all on function public.set_tournament_signup_status(uuid, text) from public;

grant execute on function public.tournament_signup_state(text) to anon, authenticated;
grant execute on function public.can_view_tournament_board() to anon, authenticated;
grant execute on function public.save_tournament_board(jsonb) to authenticated;
grant execute on function public.admin_list_tournament_signups() to authenticated;
grant execute on function public.set_tournament_signup_status(uuid, text) to authenticated;

notify pgrst, 'reload schema';
