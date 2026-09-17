-- HKOED Booking — databaseskema
--
-- Genskabt via introspektion mod det rigtige Supabase-projekt (system-
-- katalogerne pg_type/pg_class/pg_constraint/pg_policies/pg_proc/pg_trigger),
-- ikke et rent pg_dump. GRANT-statements og extensions er ikke medtaget.
-- Se CLAUDE.md for forretningsregler og kendte svagheder.

-- ============================================================
-- Enums
-- ============================================================

CREATE TYPE public.app_role AS ENUM ('admin', 'carrier');

CREATE TYPE public.booking_status AS ENUM ('AFVENTER_GODKENDELSE', 'GODKENDT', 'AFVIST', 'ANNULLERET');

CREATE TYPE public.booking_type AS ENUM ('PREBOOKING', 'BOOKING');

CREATE TYPE public.animal_category AS ENUM ('KO', 'KVIE', 'TYR', 'UNGTYR', 'STUD', 'KALV');

-- ============================================================
-- Tabeller
--
-- end_time og period var oprindeligt GENERATED ALWAYS AS (...) STORED med
-- 30 hardkodet (generated-kolonner kan kun referere kolonner i egen
-- række, ikke slå op i settings). Migreret til almindelige kolonner
-- (ALTER TABLE ... ALTER COLUMN ... DROP EXPRESSION) og sættes nu i
-- validate_booking() ud fra settings.slot_minutes. Se CLAUDE.md.
-- ============================================================

CREATE TABLE public.bookings (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  booking_date date NOT NULL,
  start_time time without time zone NOT NULL,
  slot_count integer NOT NULL DEFAULT 1,
  carrier_id uuid NOT NULL,
  farmer_id uuid NOT NULL,
  animal_count integer NOT NULL,
  n_ko integer NOT NULL DEFAULT 0,
  n_kvie integer NOT NULL DEFAULT 0,
  n_tyr integer NOT NULL DEFAULT 0,
  n_ungtyr integer NOT NULL DEFAULT 0,
  n_stud integer NOT NULL DEFAULT 0,
  n_kalv integer NOT NULL DEFAULT 0,
  type booking_type NOT NULL DEFAULT 'BOOKING'::booking_type,
  status booking_status NOT NULL DEFAULT 'AFVENTER_GODKENDELSE'::booking_status,
  note text,
  rejection_reason text,
  capacity_override boolean NOT NULL DEFAULT false,
  external_ref text,
  created_by uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_by uuid,
  updated_at timestamp with time zone,
  end_time time without time zone,
  period tsrange,
  driver_name text,
  truck_plate text,
  trailer_plate text,
  arrived_at timestamp with time zone,
  picked_up_at timestamp with time zone,
  pickup_ref text
);

CREATE TABLE public.booking_animals (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL,
  category animal_category,
  eid text,
  chr text,
  animal_no text,
  qa_mark smallint NOT NULL DEFAULT 2,
  scanned_at timestamp with time zone,
  loaded_at timestamp with time zone,
  salmonella_status text,
  remarks text,
  source text NOT NULL DEFAULT 'MANUAL'::text,
  created_by uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_by uuid,
  updated_at timestamp with time zone
);

CREATE TABLE public.carriers (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  name text NOT NULL,
  contact text,
  phone text,
  email text,
  active boolean NOT NULL DEFAULT true,
  external_ref text,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.closed_days (
  day date NOT NULL,
  reason text,
  automatic boolean NOT NULL DEFAULT false
);

CREATE TABLE public.farmers (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  name text NOT NULL,
  supplier_no text,
  active boolean NOT NULL DEFAULT true,
  external_ref text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  chr text,
  address text,
  zip_code text,
  city text
);

CREATE TABLE public.profiles (
  id uuid NOT NULL,
  role app_role NOT NULL DEFAULT 'carrier'::app_role,
  carrier_id uuid,
  full_name text,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.settings (
  id boolean NOT NULL DEFAULT true,
  opening_time time without time zone NOT NULL DEFAULT '06:00:00'::time without time zone,
  closing_time time without time zone NOT NULL DEFAULT '15:00:00'::time without time zone,
  slot_minutes integer NOT NULL DEFAULT 30,
  max_slots_per_booking integer NOT NULL DEFAULT 6,
  max_animals_per_day integer NOT NULL DEFAULT 800,
  max_animals_per_slot integer NOT NULL DEFAULT 50,
  pending_counts_in_capacity boolean NOT NULL DEFAULT true
);

-- ============================================================
-- Constraints
-- ============================================================

ALTER TABLE public.bookings ADD CONSTRAINT bookings_animal_count_check CHECK ((animal_count > 0));
ALTER TABLE public.bookings ADD CONSTRAINT bookings_carrier_id_fkey FOREIGN KEY (carrier_id) REFERENCES carriers(id);
ALTER TABLE public.bookings ADD CONSTRAINT bookings_farmer_id_fkey FOREIGN KEY (farmer_id) REFERENCES farmers(id);
ALTER TABLE public.bookings ADD CONSTRAINT bookings_no_overlap EXCLUDE USING gist (period WITH &&) WHERE ((status = ANY (ARRAY['AFVENTER_GODKENDELSE'::booking_status, 'GODKENDT'::booking_status])));
ALTER TABLE public.bookings ADD CONSTRAINT bookings_pkey PRIMARY KEY (id);
ALTER TABLE public.bookings ADD CONSTRAINT bookings_slot_count_check CHECK ((slot_count >= 1));
ALTER TABLE public.bookings ADD CONSTRAINT bookings_n_ko_check CHECK ((n_ko >= 0));
ALTER TABLE public.bookings ADD CONSTRAINT bookings_n_kvie_check CHECK ((n_kvie >= 0));
ALTER TABLE public.bookings ADD CONSTRAINT bookings_n_tyr_check CHECK ((n_tyr >= 0));
ALTER TABLE public.bookings ADD CONSTRAINT bookings_n_ungtyr_check CHECK ((n_ungtyr >= 0));
ALTER TABLE public.bookings ADD CONSTRAINT bookings_n_stud_check CHECK ((n_stud >= 0));
ALTER TABLE public.bookings ADD CONSTRAINT bookings_n_kalv_check CHECK ((n_kalv >= 0));
ALTER TABLE public.booking_animals ADD CONSTRAINT booking_animals_pkey PRIMARY KEY (id);
ALTER TABLE public.booking_animals ADD CONSTRAINT booking_animals_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES bookings(id) ON DELETE CASCADE;
ALTER TABLE public.booking_animals ADD CONSTRAINT booking_animals_qa_mark_check CHECK ((qa_mark = ANY (ARRAY[2, 3])));
ALTER TABLE public.booking_animals ADD CONSTRAINT booking_animals_source_check CHECK ((source = ANY (ARRAY['MANUAL'::text, 'WAND_UPLOAD'::text])));
ALTER TABLE public.booking_animals ADD CONSTRAINT booking_animals_eid_key UNIQUE (eid);
ALTER TABLE public.carriers ADD CONSTRAINT carriers_name_key UNIQUE (name);
ALTER TABLE public.carriers ADD CONSTRAINT carriers_pkey PRIMARY KEY (id);
ALTER TABLE public.profiles ADD CONSTRAINT chk_carrier_has_company CHECK (((role <> 'carrier'::app_role) OR (carrier_id IS NOT NULL)));
ALTER TABLE public.closed_days ADD CONSTRAINT closed_days_pkey PRIMARY KEY (day);
ALTER TABLE public.farmers ADD CONSTRAINT farmers_pkey PRIMARY KEY (id);
ALTER TABLE public.farmers ADD CONSTRAINT farmers_supplier_no_key UNIQUE (supplier_no);
ALTER TABLE public.profiles ADD CONSTRAINT profiles_carrier_id_fkey FOREIGN KEY (carrier_id) REFERENCES carriers(id);
ALTER TABLE public.profiles ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);
ALTER TABLE public.settings ADD CONSTRAINT settings_id_check CHECK (id);
ALTER TABLE public.settings ADD CONSTRAINT settings_max_animals_per_day_check CHECK ((max_animals_per_day > 0));
ALTER TABLE public.settings ADD CONSTRAINT settings_max_animals_per_slot_check CHECK ((max_animals_per_slot > 0));
ALTER TABLE public.settings ADD CONSTRAINT settings_max_slots_per_booking_check CHECK ((max_slots_per_booking > 0));
ALTER TABLE public.settings ADD CONSTRAINT settings_pkey PRIMARY KEY (id);
ALTER TABLE public.settings ADD CONSTRAINT settings_slot_minutes_check CHECK ((slot_minutes > 0));

-- ============================================================
-- Indexes
-- ============================================================

CREATE UNIQUE INDEX bookings_pkey ON public.bookings USING btree (id);
CREATE INDEX bookings_no_overlap ON public.bookings USING gist (period) WHERE (status = ANY (ARRAY['AFVENTER_GODKENDELSE'::booking_status, 'GODKENDT'::booking_status]));
CREATE INDEX idx_bookings_date ON public.bookings USING btree (booking_date);
CREATE INDEX idx_bookings_carrier ON public.bookings USING btree (carrier_id);
CREATE INDEX idx_bookings_status ON public.bookings USING btree (status);
CREATE UNIQUE INDEX closed_days_pkey ON public.closed_days USING btree (day);
CREATE UNIQUE INDEX carriers_pkey ON public.carriers USING btree (id);
CREATE UNIQUE INDEX carriers_name_key ON public.carriers USING btree (name);
CREATE UNIQUE INDEX farmers_pkey ON public.farmers USING btree (id);
CREATE UNIQUE INDEX farmers_supplier_no_key ON public.farmers USING btree (supplier_no);
CREATE UNIQUE INDEX settings_pkey ON public.settings USING btree (id);
CREATE UNIQUE INDEX profiles_pkey ON public.profiles USING btree (id);
CREATE UNIQUE INDEX booking_animals_pkey ON public.booking_animals USING btree (id);
CREATE UNIQUE INDEX booking_animals_eid_key ON public.booking_animals USING btree (eid);
CREATE INDEX idx_booking_animals_booking ON public.booking_animals USING btree (booking_id);

-- ============================================================
-- Row Level Security
-- ============================================================

ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carriers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.closed_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.farmers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.booking_animals ENABLE ROW LEVEL SECURITY;

-- Kendt svaghed: farmers_read er USING (true) — alle indloggede kan læse
-- hele leverandørlisten. Skal snævres ind når landmandsdelen bygges.
CREATE POLICY bookings_delete ON public.bookings AS PERMISSIVE FOR DELETE TO authenticated USING (is_admin());
CREATE POLICY bookings_insert ON public.bookings AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((is_admin() OR ((carrier_id = my_carrier_id()) AND (status = 'AFVENTER_GODKENDELSE'::booking_status))));
CREATE POLICY bookings_read ON public.bookings AS PERMISSIVE FOR SELECT TO authenticated USING ((is_admin() OR (carrier_id = my_carrier_id())));
CREATE POLICY bookings_update ON public.bookings AS PERMISSIVE FOR UPDATE TO authenticated USING ((is_admin() OR (carrier_id = my_carrier_id()))) WITH CHECK ((is_admin() OR (carrier_id = my_carrier_id())));
CREATE POLICY closed_read ON public.closed_days AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY closed_write ON public.closed_days AS PERMISSIVE FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY carriers_read ON public.carriers AS PERMISSIVE FOR SELECT TO authenticated USING ((is_admin() OR (id = my_carrier_id())));
CREATE POLICY carriers_write ON public.carriers AS PERMISSIVE FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY farmers_read ON public.farmers AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY farmers_write ON public.farmers AS PERMISSIVE FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY settings_read ON public.settings AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY settings_write ON public.settings AS PERMISSIVE FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY profiles_read ON public.profiles AS PERMISSIVE FOR SELECT TO authenticated USING (((id = auth.uid()) OR is_admin()));
CREATE POLICY profiles_write ON public.profiles AS PERMISSIVE FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());

-- booking_animals: samme ejerskabsmønster som bookings, men via join, da
-- ejerskab (carrier_id) ligger på den overordnede booking. Ingen maskeret
-- view — andre vognmænd skal aldrig se dyredetaljer for bookinger, de
-- ikke selv ejer.
CREATE POLICY booking_animals_select ON public.booking_animals AS PERMISSIVE FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1 FROM bookings b WHERE ((b.id = booking_animals.booking_id) AND (is_admin() OR (b.carrier_id = my_carrier_id()))))));
CREATE POLICY booking_animals_insert ON public.booking_animals AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1 FROM bookings b WHERE ((b.id = booking_animals.booking_id) AND (is_admin() OR (b.carrier_id = my_carrier_id()))))));
CREATE POLICY booking_animals_update ON public.booking_animals AS PERMISSIVE FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1 FROM bookings b WHERE ((b.id = booking_animals.booking_id) AND (is_admin() OR (b.carrier_id = my_carrier_id())))))) WITH CHECK ((EXISTS ( SELECT 1 FROM bookings b WHERE ((b.id = booking_animals.booking_id) AND (is_admin() OR (b.carrier_id = my_carrier_id()))))));
CREATE POLICY booking_animals_delete ON public.booking_animals AS PERMISSIVE FOR DELETE TO authenticated USING ((EXISTS ( SELECT 1 FROM bookings b WHERE ((b.id = booking_animals.booking_id) AND (is_admin() OR (b.carrier_id = my_carrier_id()))))));

-- ============================================================
-- Views
--
-- Kendt svaghed: v_calendar maskerer ikke slot_count og id for rækker,
-- brugeren ikke ejer.
-- ============================================================

CREATE OR REPLACE VIEW public.v_calendar AS
 SELECT b.id,
    b.booking_date,
    b.start_time,
    b.end_time,
    b.slot_count,
    b.status,
    b.type,
        CASE
            WHEN (is_admin() OR (b.carrier_id = my_carrier_id())) THEN b.animal_count
            ELSE NULL::integer
        END AS animal_count,
    (is_admin() OR (b.carrier_id = my_carrier_id())) AS is_own,
        CASE
            WHEN (is_admin() OR (b.carrier_id = my_carrier_id())) THEN c.name
            ELSE 'Optaget'::text
        END AS carrier_label,
        CASE
            WHEN (is_admin() OR (b.carrier_id = my_carrier_id())) THEN f.name
            ELSE NULL::text
        END AS farmer_label
   FROM ((bookings b
     JOIN carriers c ON ((c.id = b.carrier_id)))
     JOIN farmers f ON ((f.id = b.farmer_id)))
  WHERE (b.status = ANY (ARRAY['AFVENTER_GODKENDELSE'::booking_status, 'GODKENDT'::booking_status]));

CREATE OR REPLACE VIEW public.v_daily_load AS
 SELECT booking_date,
    COALESCE(sum(animal_count) FILTER (WHERE (status = 'GODKENDT'::booking_status)), (0)::bigint) AS animals_approved,
    COALESCE(sum(animal_count) FILTER (WHERE (status = 'AFVENTER_GODKENDELSE'::booking_status)), (0)::bigint) AS animals_pending,
    count(*) AS deliveries
   FROM bookings b
  WHERE (status = ANY (ARRAY['GODKENDT'::booking_status, 'AFVENTER_GODKENDELSE'::booking_status]))
  GROUP BY booking_date;

-- ============================================================
-- Funktioner
-- ============================================================

CREATE OR REPLACE FUNCTION public.dk_holidays(y integer)
 RETURNS TABLE(day date, reason text)
 LANGUAGE sql
 IMMUTABLE
AS $function$
  with e as (select public.easter_sunday(y) as d)
  select make_date(y,1,1),  'Nytårsdag'             from e union all
  select d - 3,             'Skærtorsdag'           from e union all
  select d - 2,             'Langfredag'            from e union all
  select d,                 'Påskedag'              from e union all
  select d + 1,             '2. påskedag'           from e union all
  select d + 39,            'Kristi himmelfartsdag' from e union all
  select d + 49,            'Pinsedag'              from e union all
  select d + 50,            '2. pinsedag'           from e union all
  select make_date(y,12,25),'Juledag'               from e union all
  select make_date(y,12,26),'2. juledag'            from e;
$function$
;

CREATE OR REPLACE FUNCTION public.easter_sunday(y integer)
 RETURNS date
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare a int; b int; c int; d int; e int; f int; g int; h int;
        i int; k int; l int; m int; mo int; da int;
begin
  a := y % 19; b := y / 100; c := y % 100; d := b / 4; e := b % 4;
  f := (b + 8) / 25; g := (b - f + 1) / 3;
  h := (19*a + b - d - g + 15) % 30;
  i := c / 4; k := c % 4;
  l := (32 + 2*e + 2*i - h - k) % 7;
  m := (a + 11*h + 22*l) / 451;
  mo := (h + l - 7*m + 114) / 31;
  da := ((h + l - 7*m + 114) % 31) + 1;
  return make_date(y, mo, da);
end $function$
;

CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.role = 'admin');
$function$
;

CREATE OR REPLACE FUNCTION public.my_carrier_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select p.carrier_id from public.profiles p where p.id = auth.uid();
$function$
;

-- Event trigger-funktion. Slår automatisk RLS til på nye tabeller i public.
-- Koblet via event triggeren ensure_rls (se nederst i filen).
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.sync_dk_holidays(from_year integer, to_year integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare y int; n int := 0; c int;
begin
  if not public.is_admin() then
    raise exception 'Kun administrator kan generere helligdage.';
  end if;
  for y in from_year..to_year loop
    with ins as (
      insert into public.closed_days (day, reason, automatic)
      select h.day, h.reason, true from public.dk_holidays(y) h
      where extract(isodow from h.day) <= 5
      on conflict (day) do nothing
      returning 1)
    select count(*) into c from ins;
    n := n + c;
  end loop;
  return n;
end $function$
;

-- Forretningsregler, kapacitetskontrol og statusovergange. Se CLAUDE.md.
--
-- Sætter new.end_time/new.period ud fra settings.slot_minutes (erstatter
-- den tidligere GENERATED-beregning, der havde 30 hardkodet).
--
-- Sætter også new.animal_count som summen af kategorikolonnerne
-- (n_ko/n_kvie/n_tyr/n_stud/n_kalv). Klienten sender ikke animal_count
-- direkte. animal_count er bevidst IKKE en GENERATED-kolonne: en BEFORE
-- trigger kan ikke læse en endnu ikke-beregnet generated-kolonne, og
-- kapacitetstjekket nedenfor har brug for værdien med det samme.
--
-- Statusnulstillingen ved transportør-rettelse af en godkendt booking
-- rammer kun de faktisk kapacitets-/planlægningsrelevante felter (præcis
-- dem bookingModal kan ændre) — ikke ren afhentningsregistrering
-- (driver_name/truck_plate/trailer_plate/pickup_ref/arrived_at/
-- picked_up_at), som ellers ville sende bookingen tilbage til
-- godkendelseskøen, hver gang chauffør eller reg.nr. blev udfyldt.
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
end $function$
;

-- Løbenummeret i pickup_ref er et globalt, aldrig-nulstillende
-- sekvensnummer (pickup_ref_seq) — ikke ét pr. dag. Datoen forrest i
-- referencen ("20260917-1") er stadig den dag afhentningen sker, men
-- tallet efter bindestregen tæller videre på tværs af alle datoer og
-- transportører, så det faktisk er løbenummeret der stiger, ikke datoen.
CREATE SEQUENCE IF NOT EXISTS public.pickup_ref_seq;
GRANT USAGE ON SEQUENCE public.pickup_ref_seq TO authenticated;

-- Sætter chauffør og reg.numre på de valgte bookinger og mærker dem med
-- fælles pickup_ref. SECURITY INVOKER (standard) - UPDATE'en nedenfor
-- kører derfor med kalderens egne rettigheder, så bookings_update-policyen
-- (kun egne bookinger, medmindre admin) håndhæves som normalt uden at
-- funktionen selv skal kende ejerskabsreglen.
--
-- Alle valgte bookinger skal have samme booking_date (så referencens
-- datodel er entydig for gruppen). Deler de allerede samme pickup_ref,
-- genbruges den (så man kan rette chauffør/reg.nr. uden at få et nyt
-- nummer); ellers tildeles et nyt fra pickup_ref_seq.
--
-- p_driver_name/p_truck_plate/p_trailer_plate er NULL/tom = "rør ikke
-- feltet" (coalesce mod den eksisterende værdi) — "Markér til
-- afhentning"-knappen i UI'et stempler kun pickup_ref uden at sende
-- chauffør/reg.numre, og skal derfor ikke kunne slette dem, hvis de
-- allerede er sat af et tidligere kald.
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
end $function$
;

-- Låser redigering af enkeltdyr når bookingen er afhentet (picked_up_at
-- sat), advarer (blokerer ikke) hvis det scannede CHR ikke matcher
-- landmandens eget registrerede CHR, og sætter created_by/updated_by/
-- updated_at. Se CLAUDE.md.
CREATE OR REPLACE FUNCTION public.validate_booking_animal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;

-- ============================================================
-- Triggers
-- ============================================================

CREATE TRIGGER trg_validate_booking BEFORE INSERT OR UPDATE ON public.bookings FOR EACH ROW EXECUTE FUNCTION validate_booking();
CREATE TRIGGER trg_validate_booking_animal BEFORE INSERT OR UPDATE ON public.booking_animals FOR EACH ROW EXECUTE FUNCTION validate_booking_animal();

-- ============================================================
-- Event triggers
-- ============================================================

CREATE EVENT TRIGGER ensure_rls ON ddl_command_end EXECUTE FUNCTION rls_auto_enable();
