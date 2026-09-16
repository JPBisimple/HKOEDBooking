-- Retter en transportør i en allerede godkendt booking, skal den igen
-- afvente admins godkendelse. Gælder enhver rettelse — inkl. "Bekræft
-- booking" (prebooking -> booking), som hidtil bevarede status uændret.
-- Rammer ikke en eksplicit annullering (status sat direkte til
-- ANNULLERET af transportøren selv), og rammer ikke admins egne
-- rettelser, da admin allerede har godkendelsesret.
--
-- Virker fordi status her nulstilles i NEW, FØR RLS'ens WITH CHECK og
-- constraints evalueres (BEFORE-trigger) — bookings_update-policyen
-- behøver ikke selv kende statusovergange.

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

  if tg_op = 'UPDATE' and not is_adm and old.status = 'GODKENDT' and new.status = 'GODKENDT' then
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
