-- Turnier der Kraft: Vorschau und Freigabe-Status für die Teilnehmerliste.
--
-- Diese Datei ändert keine Tabellen, keine Spalte status, keine Spalte
-- approval und keine bestehende Check-Constraint. Sie ersetzt nur
-- tournament_board() und legt eine neue Lesefunktion an.
-- Bestehende Anmeldungen und eine schon gespeicherte Auslosung bleiben.
-- Die Datei darf erneut laufen.
--
-- Einmal im SQL-Editor ausführen, nachdem supabase/tournament_bracket.sql
-- und supabase/tournament_approval_fix.sql gelaufen sind.
--
-- tournament_board() liefert zusätzlich "approved": die freigegebenen,
-- nicht abgemeldeten Anmeldungen (Name, Klasse, Fraktion). Nur wer den
-- Turnierbaum sehen darf, bekommt das. Die Seite baut daraus die Vorschau
-- und speichert sie nicht.
--
-- list_tournament_signup_approvals() liefert id und state
-- (pending/approved/rejected) für aktive Anmeldungen. Dieselbe Sichtbarkeit
-- wie list_tournament_signups: Offizier, freigegebenes Gildenmitglied oder
-- eigene aktive Anmeldung. Sonst eine leere Liste.

do $$
begin
  if to_regprocedure('public.can_view_tournament_board()') is null then
    raise exception 'public.can_view_tournament_board() fehlt. Zuerst tournament_bracket.sql und tournament_approval_fix.sql ausführen.';
  end if;
  if to_regprocedure('public.tournament_signup_state(text)') is null then
    raise exception 'public.tournament_signup_state(text) fehlt. Zuerst tournament_approval_fix.sql ausführen.';
  end if;
  if to_regprocedure('public.is_officer()') is null or to_regprocedure('public.is_approved()') is null then
    raise exception 'public.is_officer() oder public.is_approved() fehlt.';
  end if;
  if to_regclass('public.tournament_signups') is null then
    raise exception 'public.tournament_signups fehlt.';
  end if;
end $$;

create or replace function public.tournament_board()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_draw public.tournament_draws%rowtype;
  v_entries jsonb;
  v_groups jsonb;
  v_matches jsonb;
  v_approved jsonb;
begin
  if not public.can_view_tournament_board() then
    return jsonb_build_object('access', 'denied');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id,
    'character_name', s.character_name,
    'className', s."class",
    'faction', s.faction
  ) order by s.created_at, s.character_name), '[]'::jsonb)
  into v_approved
  from public.tournament_signups s
  where s.status is distinct from 'cancelled'
    and public.tournament_signup_state(s.approval) = 'approved';

  select * into v_draw
  from public.tournament_draws
  order by created_at desc
  limit 1;

  if v_draw.id is null then
    return jsonb_build_object('access', 'ok', 'draw', null, 'approved', v_approved);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id,
    'signupId', e.signup_id,
    'name', e.character_name,
    'className', e.class_name,
    'faction', e.faction,
    'groupId', e.group_id,
    'tiebreak', e.tiebreak
  ) order by e.tiebreak, e.character_name), '[]'::jsonb)
  into v_entries
  from public.tournament_entries e
  where e.draw_id = v_draw.id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', g.id,
    'label', g.label,
    'sort', g.sort_order
  ) order by g.sort_order), '[]'::jsonb)
  into v_groups
  from public.tournament_groups g
  where g.draw_id = v_draw.id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'stage', m.stage,
    'groupId', m.group_id,
    'round', m.round_no,
    'slot', m.slot_no,
    'a', m.player_a,
    'b', m.player_b,
    'winner', m.winner_id,
    'bye', m.is_bye,
    'byeSide', m.bye_side,
    'placeholderA', m.placeholder_a,
    'placeholderB', m.placeholder_b,
    'sourceA', case
      when m.source_a_group is null then null
      else jsonb_build_object('groupId', m.source_a_group, 'place', m.source_a_place)
    end,
    'sourceB', case
      when m.source_b_group is null then null
      else jsonb_build_object('groupId', m.source_b_group, 'place', m.source_b_place)
    end,
    'feeds', m.feeds_match,
    'feedsSlot', m.feeds_slot
  ) order by m.stage, m.round_no, m.slot_no), '[]'::jsonb)
  into v_matches
  from public.tournament_matches m
  where m.draw_id = v_draw.id;

  return jsonb_build_object(
    'access', 'ok',
    'draw', jsonb_build_object(
      'mode', v_draw.mode,
      'entries', v_entries,
      'groups', v_groups,
      'matches', v_matches
    ),
    'approved', v_approved
  );
end;
$$;

create or replace function public.list_tournament_signup_approvals()
returns table (
  id uuid,
  state text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if not (
    public.is_officer()
    or public.is_approved()
    or (v_uid is not null and exists (
          select 1 from public.tournament_signups s
          where s.user_id = v_uid and s.status = 'active'))
  ) then
    return;
  end if;

  return query
    select t.id, public.tournament_signup_state(t.approval)
    from public.tournament_signups t
    where t.status = 'active'
    order by t.created_at asc, t.id asc;
end;
$$;

alter function public.tournament_board() set row_security = off;
alter function public.list_tournament_signup_approvals() set row_security = off;

revoke all on function public.tournament_board() from public;
revoke all on function public.list_tournament_signup_approvals() from public;

grant execute on function public.tournament_board() to anon, authenticated;
grant execute on function public.list_tournament_signup_approvals() to anon, authenticated;

notify pgrst, 'reload schema';
