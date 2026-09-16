-- Enkeltdyr pr. booking: øremærke/EID, CHR, QA-mærke, læsning — samt de
-- felter der skal til for at kunne udskrive den lovpligtige "køreseddel"
-- (se CLAUDE.md). Aftalt i samtalen 2026-09-16.
--
-- CHR/animal_no udledes af EID'et fra stavens CSV-eksport (format
-- "EID;VID;Date;Time;QAMark"): EID = "208 005914700404" -> landekode 208
-- (ikke brugt endnu, til fremtidigt SEGES-opslag) + 12-cifret krop, hvor de
-- første 7 cifre er CHR og de sidste 5 er individnummeret
-- ("0059147-00404" = CHR 0059147, dyr 00404). QAMark fra filen mappes til
-- qa_mark (2=Standard, 3=Returdyr).
--
-- Salmonellastatus hentes senere fra SEGES via API — indtil da er feltet
-- tomt og udfyldes ikke automatisk.

create type public.animal_category as enum ('KO', 'KVIE', 'TYR', 'STUD', 'KALV');

create table public.booking_animals (
  id uuid not null default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  category public.animal_category not null,
  eid text,
  chr text,
  animal_no text,
  qa_mark smallint not null default 2,
  scanned_at timestamptz,
  loaded_at timestamptz,
  salmonella_status text,
  remarks text,
  source text not null default 'MANUAL',
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_by uuid,
  updated_at timestamptz,
  constraint booking_animals_pkey primary key (id),
  constraint booking_animals_qa_mark_check check (qa_mark in (2,3)),
  constraint booking_animals_source_check check (source in ('MANUAL','WAND_UPLOAD'))
);

create unique index booking_animals_eid_key on public.booking_animals (eid) where (eid is not null);
create index idx_booking_animals_booking on public.booking_animals (booking_id);

-- Felter til køreseddel og afhentningsflow
alter table public.bookings
  add column driver_name text,
  add column truck_plate text,
  add column trailer_plate text,
  add column arrived_at timestamptz,
  add column picked_up_at timestamptz;

alter table public.farmers
  add column chr text,
  add column address text,
  add column zip_code text,
  add column city text;

-- RLS: samme mønster som bookings — kun ejeren af den tilhørende booking
-- (vognmandens egen carrier_id) eller admin. Ingen maskeret view
-- nødvendig, da andre vognmænd aldrig skal se dyredetaljer for bookinger,
-- de ikke selv ejer.
alter table public.booking_animals enable row level security;

create policy booking_animals_select on public.booking_animals as permissive for select to authenticated
  using (exists (select 1 from public.bookings b where b.id = booking_animals.booking_id
                 and (is_admin() or b.carrier_id = my_carrier_id())));

create policy booking_animals_insert on public.booking_animals as permissive for insert to authenticated
  with check (exists (select 1 from public.bookings b where b.id = booking_animals.booking_id
                 and (is_admin() or b.carrier_id = my_carrier_id())));

create policy booking_animals_update on public.booking_animals as permissive for update to authenticated
  using (exists (select 1 from public.bookings b where b.id = booking_animals.booking_id
                 and (is_admin() or b.carrier_id = my_carrier_id())))
  with check (exists (select 1 from public.bookings b where b.id = booking_animals.booking_id
                 and (is_admin() or b.carrier_id = my_carrier_id())));

create policy booking_animals_delete on public.booking_animals as permissive for delete to authenticated
  using (exists (select 1 from public.bookings b where b.id = booking_animals.booking_id
                 and (is_admin() or b.carrier_id = my_carrier_id())));

-- Trigger: låser redigering når bookingen er afhentet (picked_up_at sat),
-- advarer (blokerer ikke) hvis det scannede CHR ikke matcher landmandens
-- eget registrerede CHR, og sætter created_by/updated_by/updated_at.
create or replace function public.validate_booking_animal()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  b public.bookings%rowtype;
  f public.farmers%rowtype;
  is_adm boolean := public.is_admin();
begin
  select * into b from public.bookings where id = new.booking_id;
  if not found then
    raise exception 'Ukendt booking.';
  end if;

  if not is_adm and b.picked_up_at is not null then
    raise exception 'Bookingen er allerede afhentet — dyredata kan ikke længere rettes.';
  end if;

  if new.chr is not null then
    select * into f from public.farmers where id = b.farmer_id;
    if found and f.chr is not null and f.chr <> new.chr then
      raise notice 'Scannet CHR (%) matcher ikke landmandens registrerede CHR (%).', new.chr, f.chr;
    end if;
  end if;

  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, auth.uid());
  else
    new.updated_at := now();
    new.updated_by := auth.uid();
  end if;

  return new;
end $function$;

create trigger trg_validate_booking_animal
  before insert or update on public.booking_animals
  for each row execute function validate_booking_animal();
