-- Den nye "Markér til afhentning"-knap (adskilt fra køreseddel-modalen)
-- stempler kun de markerede bookinger med en pickup_ref uden at ville
-- sætte chauffør/reg.numre samtidig — den sender derfor NULL for
-- p_driver_name/p_truck_plate/p_trailer_plate. Den forrige version af
-- assign_pickup_ref satte kolonnerne ubetinget (nullif(trim(...),'') er
-- stadig NULL for et NULL-input), så et sådant kald ville have slettet et
-- allerede indtastet chaufførnavn. NULL/tom streng betyder nu i stedet
-- "rør ikke feltet" — kun en faktisk værdi overskriver.
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
  v_n        int;
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
    perform pg_advisory_xact_lock(hashtext('pickup_ref:' || v_date::text));
    select count(distinct pickup_ref) into v_n
    from public.bookings where booking_date = v_date and pickup_ref is not null;
    v_ref := to_char(v_date,'YYYYMMDD') || '-' || (v_n + 1);
  end if;

  update public.bookings set
    pickup_ref    = v_ref,
    driver_name   = coalesce(nullif(trim(p_driver_name), ''), driver_name),
    truck_plate   = coalesce(nullif(trim(p_truck_plate), ''), truck_plate),
    trailer_plate = coalesce(nullif(trim(p_trailer_plate), ''), trailer_plate)
  where id = any(p_booking_ids);

  return v_ref;
end $function$;
