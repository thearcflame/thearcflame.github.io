-- Turnier der Kraft: Anmeldung ohne Konto, öffentlicher Turnierbaum.
--
-- Diese Datei legt neue Funktionen an und ersetzt nur
-- can_view_tournament_board(), damit der Baum öffentlich lesbar ist.
-- Sie löscht keine Funktion, keine Policy und keine Zeile.
-- submit_tournament_signup bleibt unverändert.
-- status bleibt active/cancelled. Neue Anmeldungen bekommen
-- status active und approval pending. user_id bleibt leer.
-- Die Datei darf erneut laufen.
--
-- Einmal im SQL-Editor ausführen, nachdem supabase/tournament_bracket.sql
-- und supabase/tournament_approval_fix.sql gelaufen sind.
--
-- Schutz vor Spam in submit_tournament_signup_public:
--   eine aktive Anmeldung pro Discord-Name,
--   höchstens 8 Anmeldungen pro Minute insgesamt,
--   Charaktername nur einmal unter den nicht abgemeldeten Zeilen.
-- p_website ist ein Honeypot. Ist das Feld gefüllt, wird nichts gespeichert.

do $$
begin
  if to_regprocedure('public.tournament_signup_state(text)') is null then
    raise exception 'public.tournament_signup_state(text) fehlt. Zuerst tournament_approval_fix.sql ausführen.';
  end if;
  if to_regprocedure('public.can_view_tournament_board()') is null then
    raise exception 'public.can_view_tournament_board() fehlt. Zuerst tournament_bracket.sql ausführen.';
  end if;
  if to_regclass('public.tournament_signups') is null then
    raise exception 'public.tournament_signups fehlt.';
  end if;
end $$;

create or replace function public.can_view_tournament_board()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select true;
$$;

comment on function public.can_view_tournament_board() is
  'Turnierbaum ist öffentlich. Schreiben bleibt bei is_admin().';

create or replace function public.submit_tournament_signup_public(
  p_character_name text,
  p_class text,
  p_faction text,
  p_discord_name text,
  p_website text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := btrim(coalesce(p_character_name, ''));
  v_class text := btrim(coalesce(p_class, ''));
  v_faction text := lower(btrim(coalesce(p_faction, '')));
  v_discord text := btrim(coalesce(p_discord_name, ''));
  v_id uuid;
  v_per_discord constant int := 1;
  v_per_minute constant int := 8;
begin
  perform pg_advisory_xact_lock(hashtext('tournament_public_signup'));

  if btrim(coalesce(p_website, '')) <> '' then
    return gen_random_uuid();
  end if;

  if char_length(v_name) < 2 or char_length(v_name) > 24 then
    raise exception 'Bitte einen Charakternamen mit 2 bis 24 Zeichen eingeben.';
  end if;
  if v_class not in (
    'Krieger', 'Paladin', 'Jäger', 'Schurke', 'Priester',
    'Schamane', 'Magier', 'Hexenmeister', 'Druide'
  ) then
    raise exception 'Bitte eine Klasse aus der Liste wählen.';
  end if;
  v_faction := case v_faction
    when 'horde' then 'horde'
    when 'alliance' then 'alliance'
    when 'allianz' then 'alliance'
    else null
  end;
  if v_faction is null then
    raise exception 'Bitte Horde oder Allianz wählen.';
  end if;
  if char_length(v_discord) < 2 or char_length(v_discord) > 40 then
    raise exception 'Bitte einen Discord-Namen mit 2 bis 40 Zeichen eingeben.';
  end if;

  if exists (
    select 1
    from public.tournament_signups t
    where t.status is distinct from 'cancelled'
      and lower(t.character_name) = lower(v_name)
  ) then
    raise exception 'Der Charakter „%“ ist schon angemeldet.', v_name;
  end if;

  if (
    select count(*)
    from public.tournament_signups t
    where t.status is distinct from 'cancelled'
      and lower(t.discord_name) = lower(v_discord)
  ) >= v_per_discord then
    raise exception 'Dieser Discord-Name ist schon angemeldet.';
  end if;

  if (
    select count(*)
    from public.tournament_signups t
    where t.created_at > now() - interval '1 minute'
  ) >= v_per_minute then
    raise exception 'Gerade kommen viele Anmeldungen. Bitte eine Minute warten.';
  end if;

  insert into public.tournament_signups (
    character_name, class, faction, discord_name, user_id, status, approval
  )
  values (v_name, v_class, v_faction, v_discord, null, 'active', 'pending')
  returning id into v_id;

  return v_id;
exception
  when unique_violation then
    raise exception 'Der Charakter „%“ ist schon angemeldet.', v_name;
end;
$$;

create or replace function public.list_public_tournament_signups()
returns table (
  id uuid,
  created_at timestamptz,
  character_name text,
  class text,
  faction text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    s.id,
    s.created_at,
    s.character_name,
    s.class,
    s.faction
  from public.tournament_signups s
  where s.status is distinct from 'cancelled'
    and public.tournament_signup_state(s.approval) = 'approved'
  order by s.created_at, s.character_name;
$$;

comment on function public.list_public_tournament_signups() is
  'Nur freigegebene, nicht abgemeldete Teilnehmer. Ohne Discord-Namen.';

alter function public.can_view_tournament_board() set row_security = off;
alter function public.submit_tournament_signup_public(text, text, text, text, text) set row_security = off;
alter function public.list_public_tournament_signups() set row_security = off;

revoke all on function public.submit_tournament_signup_public(text, text, text, text, text) from public;
revoke all on function public.list_public_tournament_signups() from public;

grant execute on function public.can_view_tournament_board() to anon, authenticated;
grant execute on function public.submit_tournament_signup_public(text, text, text, text, text) to anon, authenticated;
grant execute on function public.list_public_tournament_signups() to anon, authenticated;

notify pgrst, 'reload schema';
