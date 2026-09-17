-- Chauffør og registreringsnumre havde slet ingen UI-indgang, selvom
-- kolonnerne (driver_name/truck_plate/trailer_plate) altid har eksisteret.
-- De sættes nu fra "Vis køreseddel"-modalen, hvor en vognmand markerer
-- flere bookinger til samme fysiske afhentning.
--
-- Ny kolonne pickup_ref mærker de bookinger, der hører til samme
-- afhentning, med et løbenummer pr. dag: "20260917-1". Tildeles atomisk
-- af assign_pickup_ref() (samme lås-mønster som validate_booking bruger
-- til dagskapaciteten), så to samtidige grupperinger samme dag ikke kan
-- få samme nummer.
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS pickup_ref text;

-- validate_booking sendte hidtil ENHVER transportør-rettelse af en
-- godkendt booking tilbage til AFVENTER_GODKENDELSE — inkl. rene
-- afhentnings-detaljer (chauffør, reg.numre, gruppering, "Bekræft
-- afhentning"), som ikke ændrer tid, kapacitet eller landmand. Det ville
-- gøre den nye afhentningsregistrering ubrugelig, fordi hver justering af
-- chauffør/reg.nr. ville sende bookingen tilbage til slagteriets
-- godkendelseskø. Nulstillingen udløses nu kun, når et af de faktisk
-- kapacitets-/planlægningsrelevante felter ændres — præcis de felter
-- bookingModal kan ændre (inkl. type, jf. "Bekræft booking"). Ren
-- afhentningsregistrering (driver_name/truck_plate/trailer_plate/
-- pickup_ref/arrived_at/picked_up_at) rammer den ikke længere.
CREATE OR REPLACE FUNCTION public.validate_booking()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s      public.settings%rowtype;
  booked int;
  is_adm boolean := public.is_admin();
begin
  select * into s from public.settings where id;
  perform pg_advisory_xact_lock(hashtext(new.booking_date::text));

  new.animal_count := coalesce(new.n_ko,0) + coalesce(new.n_kvie,0) + coalesce(new.n_tyr,0)
                     + coalesce(new.n_stud,0) + coalesce(new.n_kalv,0);

  if tg_op = 'UPDATE' and not is_adm and old.status = 'GODKENDT' and new.status = 'GODKENDT'
     and (new.booking_date is distinct from old.booking_date
          or new.start_time is distinct from old.start_time
          or new.slot_count is distinct from old.slot_count
          or new.carrier_id is distinct from old.carrier_id
          or new.farmer_id  is distinct from old.farmer_id
          or new.n_ko   is distinct from old.n_ko
          or new.n_kvie is distinct from old.n_kvie
          or new.n_tyr  is distinct from old.n_tyr
          or new.n_stud is distinct from old.n_stud
          or new.n_kalv is distinct from old.n_kalv
          or new.type   is distinct from old.type
          or new.note   is distinct from old.note)
  then
    new.status := 'AFVENTER_GODKENDELSE';
  end if;

  new.end_time := new.start_time + make_interval(mins => new.slot_count * s.slot_minutes);
  new.period := tsrange(
    (new.booking_date + new.start_time),
    (new.booking_date + new.start_time) + make_interval(mins => new.slot_count * s.slot_minutes),
    '[)'
  );

  if new.status in ('AFVENTER_GODKENDELSE','GODKENDT') then

    if extract(isodow from new.booking_date) > 5 then
      raise exception 'Der kan kun bookes på hverdage (mandag-fredag).';
    end if;

    if exists (select 1 from public.closed_days c where c.day = new.booking_date) then
      raise exception 'Datoen % er en lukkedag.', new.booking_date;
    end if;

    if new.start_time < s.opening_time or new.start_time >= s.closing_time then
      raise exception 'Starttid skal ligge i intervallet %-%.', s.opening_time, s.closing_time;
    end if;

    if (new.start_time + make_interval(mins => new.slot_count * s.slot_minutes)) > s.closing_time then
      raise exception 'Bookingen slutter efter lukketid (%).', s.closing_time;
    end if;

    if (extract(epoch from new.start_time)::int - extract(epoch from s.opening_time)::int)
       % (s.slot_minutes * 60) <> 0 then
      raise exception 'Starttid skal ligge på et %-minutters interval.', s.slot_minutes;
    end if;

    if new.slot_count > s.max_slots_per_booking then
      raise exception 'Maks % sammenhængende intervaller pr. booking.', s.max_slots_per_booking;
    end if;

    -- Kapacitet pr. interval — admin kan tilsidesætte med capacity_override,
    -- ligesom dagskapaciteten nedenfor.
    if new.animal_count > new.slot_count * s.max_animals_per_slot then
      if is_adm and new.capacity_override then
        raise notice 'Kapacitet pr. interval overskredet - tilsidesat af administrator.';
      else
        raise exception '% dyr kræver mindst % intervaller (maks % dyr pr. interval).',
          new.animal_count,
          ceil(new.animal_count::numeric / s.max_animals_per_slot),
          s.max_animals_per_slot;
      end if;
    end if;

    -- Dagskapacitet
    select coalesce(sum(b.animal_count),0) into booked
    from public.bookings b
    where b.booking_date = new.booking_date
      and b.id <> new.id
      and (b.status = 'GODKENDT'
           or (s.pending_counts_in_capacity and b.status = 'AFVENTER_GODKENDELSE'));

    if booked + new.animal_count > s.max_animals_per_day then
      if is_adm and new.capacity_override then
        raise notice 'Dagskapacitet overskredet - tilsidesat af administrator.';
      else
        raise exception 'Dagskapacitet overskredet: % allerede booket + % dyr > %.',
          booked, new.animal_count, s.max_animals_per_day;
      end if;
    end if;
  end if;

  if tg_op = 'UPDATE' then
    if new.status is distinct from old.status
       and new.status in ('GODKENDT','AFVIST') and not is_adm then
      raise exception 'Kun administrator kan godkende eller afvise bookinger.';
    end if;
    new.updated_at := now();
    new.updated_by := auth.uid();
  end if;

  if new.capacity_override and not is_adm then
    raise exception 'Kun administrator kan tilsidesætte kapaciteten.';
  end if;

  return new;
end $function$;

-- Sætter chauffør og reg.numre på de valgte bookinger og mærker dem med
-- fælles pickup_ref. SECURITY INVOKER (standard) - UPDATE'en nedenfor
-- kører derfor med kalderens egne rettigheder, så bookings_update-policyen
-- (kun egne bookinger, medmindre admin) håndhæves som normalt uden at
-- funktionen selv skal kende ejerskabsreglen.
--
-- Alle valgte bookinger skal have samme booking_date, så løbenummeret
-- ("20260917-1") er entydigt pr. dag. Deler de allerede samme pickup_ref,
-- genbruges den (så man kan rette chauffør/reg.nr. uden at få et nyt
-- nummer); ellers tildeles et nyt, låst med samme
-- pg_advisory_xact_lock-mønster som dagskapaciteten i validate_booking,
-- så to samtidige grupperinger samme dag ikke kan kollidere.
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
    driver_name   = nullif(trim(p_driver_name), ''),
    truck_plate   = nullif(trim(p_truck_plate), ''),
    trailer_plate = nullif(trim(p_trailer_plate), '')
  where id = any(p_booking_ids);

  return v_ref;
end $function$;
