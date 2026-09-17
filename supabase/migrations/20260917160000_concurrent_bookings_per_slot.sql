-- Tillader flere transportører at booke samme interval samtidig.
--
-- Fabrikken har 7 fysiske porte til aflæsning, ikke én — men
-- bookings_no_overlap (EXCLUDE USING gist (period WITH &&)) forbød al
-- overlap mellem to bookinger, dvs. antog implicit kun én port pr.
-- interval. Erstattet af en samtidighedstælling i validate_booking() mod
-- den nye indstilling max_concurrent_bookings_per_slot (default 6 — den
-- 7. port er reserveret og kan kun bruges af administrator via
-- capacity_override). Der tildeles ikke en bestemt fysisk port til den
-- enkelte booking; se CLAUDE.md, "Fysiske porte", for hvorfor.

alter table public.settings
  add column max_concurrent_bookings_per_slot integer not null default 6;

alter table public.settings
  add constraint settings_max_concurrent_bookings_per_slot_check
  check (max_concurrent_bookings_per_slot > 0);

alter table public.bookings drop constraint bookings_no_overlap;

create index idx_bookings_period on public.bookings using gist (period)
  where (status = any (array['AFVENTER_GODKENDELSE'::booking_status, 'GODKENDT'::booking_status]));

create or replace function public.validate_booking()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  s          public.settings%rowtype;
  booked     int;
  concurrent int;
  is_adm     boolean := public.is_admin();
begin
  select * into s from public.settings where id;
  perform pg_advisory_xact_lock(hashtext(new.booking_date::text));

  new.animal_count := coalesce(new.n_ko,0) + coalesce(new.n_kvie,0) + coalesce(new.n_tyr,0)
                     + coalesce(new.n_ungtyr,0) + coalesce(new.n_stud,0) + coalesce(new.n_kalv,0);

  if tg_op = 'UPDATE' and not is_adm and old.status = 'GODKENDT' and new.status = 'GODKENDT'
     and (new.booking_date is distinct from old.booking_date
          or new.start_time is distinct from old.start_time
          or new.slot_count is distinct from old.slot_count
          or new.carrier_id is distinct from old.carrier_id
          or new.farmer_id  is distinct from old.farmer_id
          or new.n_ko     is distinct from old.n_ko
          or new.n_kvie   is distinct from old.n_kvie
          or new.n_tyr    is distinct from old.n_tyr
          or new.n_ungtyr is distinct from old.n_ungtyr
          or new.n_stud   is distinct from old.n_stud
          or new.n_kalv   is distinct from old.n_kalv
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

    -- Kapacitet pr. interval (dyr pr. booking) — admin kan tilsidesætte
    -- med capacity_override, ligesom dagskapaciteten nedenfor.
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

    -- Samtidige bookinger pr. interval (fysiske porte). Fabrikken har 7
    -- porte; normal kapacitet er max_concurrent_bookings_per_slot (6) —
    -- den 7. er reserveret og kræver admins capacity_override. Tjekket
    -- regner det højeste antal samtidige bookinger på tværs af ALLE
    -- delintervaller, den nye booking dækker (ikke kun "overlapper et
    -- sted"), så en flerintervals-booking ikke kan snige sig forbi et
    -- fyldt delinterval, blot fordi et andet delinterval har ledig plads.
    select coalesce(max(cnt), 0) into concurrent
    from (
      select count(b.id) as cnt
      from generate_series(
             lower(new.period), upper(new.period) - make_interval(mins => s.slot_minutes),
             make_interval(mins => s.slot_minutes)
           ) as pt
      left join public.bookings b
        on b.id <> new.id
       and b.status in ('AFVENTER_GODKENDELSE','GODKENDT')
       and b.period @> pt
      group by pt
    ) counts;

    if concurrent >= s.max_concurrent_bookings_per_slot then
      if is_adm and new.capacity_override then
        raise notice 'Antal samtidige bookinger i intervallet overskredet - tilsidesat af administrator.';
      else
        raise exception 'Intervallet er fuldt booket (maks % samtidige leverancer).', s.max_concurrent_bookings_per_slot;
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
