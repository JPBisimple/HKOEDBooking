-- UI'et viste kun markeringscheckboksen for GODKENDT og AFVENTER_GODKENDELSE
-- ("Afventer slagteri") bookinger — men en booking, slagteriet ikke har
-- godkendt endnu, skal ikke kunne indgå i en afhentningsplan. Rettet i
-- klienten (pickable() i index.html), og håndhæves nu også her, så et
-- direkte RPC-kald ikke kan omgå UI-begrænsningen (jf. CLAUDE.md: "At en
-- knap er skjult, beskytter ingenting").
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

  if exists (
    select 1 from public.bookings where id = any(p_booking_ids) and status <> 'GODKENDT'
  ) then
    raise exception 'Kun godkendte bookinger kan markeres til afhentning.';
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
