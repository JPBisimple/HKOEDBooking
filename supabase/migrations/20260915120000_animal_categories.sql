-- Dyr pr. kategori på bookings (Ko/Kvie/Tyr/Stud/Kalv) i stedet for ét samlet
-- "antal dyr"-felt indtastet direkte. animal_count er stadig kolonnen som
-- kapacitet og rapportering (v_daily_load, v_calendar) læser fra — den
-- sættes nu af validate_booking() som summen af kategorierne og kan ikke
-- længere sættes direkte af klienten. Se CLAUDE.md.

alter table public.bookings
  add column n_ko   integer not null default 0,
  add column n_kvie integer not null default 0,
  add column n_tyr  integer not null default 0,
  add column n_stud integer not null default 0,
  add column n_kalv integer not null default 0;

alter table public.bookings
  add constraint bookings_n_ko_check   check (n_ko   >= 0),
  add constraint bookings_n_kvie_check check (n_kvie >= 0),
  add constraint bookings_n_tyr_check  check (n_tyr  >= 0),
  add constraint bookings_n_stud_check check (n_stud >= 0),
  add constraint bookings_n_kalv_check check (n_kalv >= 0);

-- Eksisterende bookinger har ingen kategoridata. Antag ko, indtil
-- administrationen retter dem manuelt.
update public.bookings set n_ko = animal_count where animal_count > 0;

create or replace function public.validate_booking()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  s      public.settings%rowtype;
  booked int;
  is_adm boolean := public.is_admin();
begin
  select * into s from public.settings where id;
  perform pg_advisory_xact_lock(hashtext(new.booking_date::text));

  new.animal_count := coalesce(new.n_ko,0) + coalesce(new.n_kvie,0) + coalesce(new.n_tyr,0)
                     + coalesce(new.n_stud,0) + coalesce(new.n_kalv,0);

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
      raise exception 'Starttid skal ligge på et %-minutters slot.', s.slot_minutes;
    end if;

    if new.slot_count > s.max_slots_per_booking then
      raise exception 'Maks % sammenhængende slots pr. booking.', s.max_slots_per_booking;
    end if;

    -- Kapacitet pr. slot
    if new.animal_count > new.slot_count * s.max_animals_per_slot then
      raise exception '% dyr kræver mindst % slots (maks % dyr pr. slot).',
        new.animal_count,
        ceil(new.animal_count::numeric / s.max_animals_per_slot),
        s.max_animals_per_slot;
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
    raise exception 'Kun administrator kan tilsidesætte dagskapaciteten.';
  end if;

  return new;
end $function$;
