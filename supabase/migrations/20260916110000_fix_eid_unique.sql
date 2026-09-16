-- Det delvise unikke indeks (WHERE eid IS NOT NULL) kan ikke bruges som
-- ON CONFLICT-mål af PostgREST/supabase-js's upsert(), fordi den
-- genererede "ON CONFLICT (eid)"-klausul ikke selv gentager WHERE-
-- betingelsen ("there is no unique or exclusion constraint matching the
-- ON CONFLICT specification"). Et almindeligt unikt constraint er nok:
-- Postgres udelukker aldrig NULL fra sig selv i et unikt indeks, så flere
-- rækker med eid = NULL er stadig tilladt.

drop index if exists public.booking_animals_eid_key;
alter table public.booking_animals add constraint booking_animals_eid_key unique (eid);
