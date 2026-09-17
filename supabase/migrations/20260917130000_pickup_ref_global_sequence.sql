-- Løbenummeret i pickup_ref ("20260917-1") talte hidtil pr. dag: hver ny
-- dato startede forfra ved 1, så to afhentninger på forskellige datoer
-- kunne begge hedde "...-1" — det så ud som om det var DATOEN, der talte
-- op, ikke løbenummeret. Nu er det et globalt, aldrig-nulstillende
-- sekvensnummer (pickup_ref_seq): datoen i starten af referencen er stadig
-- den dag afhentningen faktisk sker, men tallet efter bindestregen tæller
-- videre på tværs af alle datoer og transportører.
--
-- Sekvensen sættes til at fortsætte efter det højeste tal, der allerede
-- er brugt i eksisterende pickup_ref-værdier, så nye referencer ikke kan
-- kollidere med tal, der allerede er uddelt under den gamle pr.
-- dag-ordning.
CREATE SEQUENCE IF NOT EXISTS public.pickup_ref_seq;

DO $$
declare
  v_max bigint;
begin
  select coalesce(max(substring(pickup_ref from '-([0-9]+)$')::bigint), 0) into v_max
  from public.bookings where pickup_ref is not null;
  if v_max > 0 then
    perform setval('public.pickup_ref_seq', v_max, true);
  end if;
end $$;

GRANT USAGE ON SEQUENCE public.pickup_ref_seq TO authenticated;

CREATE OR REPLACE FUNCTION public.assign_pickup_ref(
  p_booking_ids uuid[], p_driver_name text, p_truck_plate text, p_trailer_plate text
) RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_date     date;
  v_ref      text;
  v_existing text;
begin
  if p_booking_ids is null or array_length(p_booking_ids,1) is null then
    raise exception 'Ingen bookinger valgt.';
  end if;

  select booking_date into v_date from public.bookings where id = p_booking_ids[1];
  if v_date is null then
    raise exception 'Booking ikke fundet.';
  end if;

  if exists (
    select 1 from public.bookings where id = any(p_booking_ids) and booking_date <> v_date
  ) then
    raise exception 'Alle valgte bookinger skal have samme dato for at kunne grupperes til én afhentning.';
  end if;

  select pickup_ref into v_existing from public.bookings where id = p_booking_ids[1];
  if v_existing is not null and not exists (
    select 1 from public.bookings where id = any(p_booking_ids) and pickup_ref is distinct from v_existing
  ) then
    v_ref := v_existing;
  else
    v_ref := to_char(v_date,'YYYYMMDD') || '-' || nextval('public.pickup_ref_seq');
  end if;

  update public.bookings set
    pickup_ref    = v_ref,
    driver_name   = coalesce(nullif(trim(p_driver_name), ''), driver_name),
    truck_plate   = coalesce(nullif(trim(p_truck_plate), ''), truck_plate),
    trailer_plate = coalesce(nullif(trim(p_trailer_plate), ''), trailer_plate)
  where id = any(p_booking_ids);

  return v_ref;
end $function$;
