# HKOED Booking

Bookingsystem til modtagelse af kvæg på Himmerlandskød.

> Afsnit markeret `<!-- UDFYLD -->` er ikke besluttet endnu.
> Alt under "Sådan er det bygget i dag" er verificeret mod `index.html`.

---

## Stak

- Statisk HTML/CSS/JS i én fil (`index.html`), ingen byggeproces, intet framework
- Supabase som database og auth (`supabase-js@2` via CDN, ES-modul)
- Hostet på GitHub Pages fra et **offentligt** repo
- Konfiguration i `config.js` (`window.APP_CONFIG`)

Al klientkode er offentligt læsbar. Kun den publicerbare nøgle må ligge i
`config.js`. En `sb_secret_...`-nøgle i repoet er et brud, ikke en fejl.

## Sikkerhedsmodel

**Al adgangskontrol ligger i databasen.** Ikke i UI'et. At en knap er skjult,
beskytter ingenting.

Vognmænd er konkurrenter. Alt hvad der ikke tilhører vognmanden selv, vises
som **"optaget"** — ingen navne, ingen antal, ingen CHR-numre.

### Mønsteret — følg det for nye tabeller

Tre lag, hvert med sin opgave:

1. **RLS-policy på tabellen.** Bestemmer hvilke *rækker* brugeren må røre.
   Policies hænger på to hjælpefunktioner: `is_admin()` og `my_carrier_id()`,
   som begge slår op i `profiles` via `auth.uid()`.
2. **View til visning af andres data.** Views omgår RLS, så maskeringen skal
   ske i selve SELECT-listen — felter sættes til NULL eller en fast tekst for
   rækker, brugeren ikke ejer. Se `v_calendar`. **Maskér i view'et, aldrig i
   klienten:** et felt, der hentes og skjules i UI'et, er lækket.
3. **Trigger til validering.** Forretningsregler og statusovergange. Se
   `validate_booking`.

Nye tabeller i `public` får automatisk RLS slået til (event trigger
`ensure_rls`, som kalder funktionen `rls_auto_enable()`). RLS uden policies
betyder **ingen adgang** — husk at skrive policies, ellers virker intet.

`anon` har ingen læse- eller skriverettigheder. Det skal forblive sådan.

### Kendte svagheder — ret dem, når landmandsdelen bygges

`end_time` og `period` var oprindeligt `GENERATED ALWAYS AS (...) STORED`
med `30` hardkodet (generated-kolonner kan kun referere kolonner i egen
række, ikke slå op i `settings`). **Rettet:** kolonnerne er migreret til
almindelige kolonner, og `validate_booking` sætter nu `new.end_time` og
`new.period` ud fra `settings.slot_minutes` ved hver INSERT/UPDATE.
Dobbeltbooking spærres af `bookings_no_overlap`
(`EXCLUDE USING gist (period WITH &&)` for status `AFVENTER_GODKENDELSE`
og `GODKENDT`), som nu regner rigtigt uanset `slot_minutes`.

- `farmers_read` er `true`. Alle indloggede kan læse hele leverandørlisten.
  Får landmænd login, kan hver landmand se alle andre. Skal snævres ind.
- Statuseskalering blokeres kun af `validate_booking`, ikke af
  `bookings_update`-policyen. Fjernes triggeren, er godkendelsesflowet åbent.
- `v_calendar` maskerer ikke `slot_count` og `id`.
- `anon` har TRUNCATE på alle tabeller (Supabase-standard). Ikke verificeret
  om det kan udnyttes via REST-API'et.

### Fejlkoder oversat i klienten

- `42501` / "row-level security" → "Du har ikke rettigheder til denne handling."
- `23P01` (exclusion constraint) → dobbeltbooking af samme slot

---

## Sådan virker forretningen

### Tilmelding

Landmanden melder dyr til slagtning. To indgange, samme resultat:

1. **Landmanden selv i appen.** Han vælger vognmand. Har han en foretrukken
   vognmand tilknyttet, er den forudfyldt.
2. **Telefon.** Mange landmænd er teknologiforskrækkede og ringer i stedet
   til en vognmand, som taster tilmeldingen ind på deres vegne.

Vognmanden skal altså kunne oprette en tilmelding for en landmand, der ikke
selv bruger systemet.

Landmanden angiver en **ønsket afhentningsdato** ved tilmeldingen. Det er et
ønske, ikke en aftale — vognmanden er ikke bundet af den.

**Der er ingen tilmeldingsfrist.** Først til mølle.

### Booking

Vognmanden planlægger. Rækkefølgen er:

1. Han ser, hvilke slots der er ledige på slagteriet
2. Han booker afleveringstid
3. Han aftaler derefter afhentning hos landmændene

Han planlægger ruten ud fra sin egen kapacitet og sin egen geografikendskab.
Systemet beregner ikke ruter og beregner ikke transporttid. En tilmelding kan
derfor aldrig overstige bilens kapacitet — vognmanden styrer det selv.

### Afhentningstidspunkt

**Vognmanden indtaster dato og tidspunkt manuelt pr. tilmelding.** Systemet
udleder det ikke og beregner ikke ruter.

To adskilte felter, som aldrig må overskrive hinanden:

- **Ønsket dato** — sat af landmanden ved tilmelding. Vognmanden kan ikke ændre den.
- **Aftalt dato og tidspunkt** — sat af vognmanden. Tom indtil han har planlagt.

Landmanden skal kunne se begge, så han kan se, om ønsket blev imødekommet,
eller om der bare ikke er planlagt endnu.

**Vognmanden giver selv landmanden besked** — telefon, SMS, uden for
systemet. Appen sender ingen notifikationer og skal ikke bygges til det.
Den er opslagsstedet, ikke beskedkanalen.

### Tilmeldingen godkendes ikke

En tilmelding har **ingen godkendelsesstatus**. Den er data, der venter på at
komme med en bil. Administrationen godkender bookinger — ikke tilmeldinger.

### Hvad vognmanden må

- Ser og redigerer kun egne tilmeldinger
- Kan rette dem, indtil de er koblet til en godkendt booking. Derefter er
  dyrene på vej, og listen ligger fast.
- Alt andet i systemet er "optaget"

---

## Sådan er det bygget i dag

Kun booking-delen findes. Tilmelding er ikke bygget.

### Roller

| Rolle | Kilde | Kan |
|---|---|---|
| `admin` | `profiles.role = 'admin'` | Alt: godkende, afvise, rette, slette, ændre indstillinger |
| Vognmand | alt andet end `admin` | Sende forespørgsler, se og annullere egne |

Rolle hentes fra `profiles` ved login. Uden profilrække nægtes adgang.
Login er e-mail + password (`signInWithPassword`).

**Landmænd er i dag data, ikke brugere.** `farmers` er en fast liste, som
vognmanden vælger fra. Ingen landmandsrolle, intet landmands-UI.

### Datamodel

Tabeller: `profiles`, `bookings`, `carriers`, `farmers`, `closed_days`, `settings`
Views: `v_calendar` (maskeret kalender), `v_daily_load` (aggregeret dagsbelastning)
Funktioner: `is_admin()`, `my_carrier_id()`, `validate_booking()` (trigger),
`sync_dk_holidays(from_year, to_year)`, `dk_holidays(y)`, `easter_sunday(y)`

Enums:
- `app_role`: `admin`, `carrier`
- `booking_status`: `AFVENTER_GODKENDELSE`, `GODKENDT`, `AFVIST`, `ANNULLERET`
- `booking_type`: `PREBOOKING`, `BOOKING`

`profiles` har `carrier_id` med fremmednøgle til `carriers`, og
`chk_carrier_has_company` kræver, at en bruger med rollen `carrier` altid har
et firma. **En landmandsrolle kræver derfor både en ny `app_role`-værdi og en
måde at pege på `farmers` — profiltabellen skal udvides.** Check-constraint'en
er formuleret, så en ny rolle ikke automatisk kræver `carrier_id`.

`bookings`: `booking_date`, `start_time`, `slot_count`, `animal_count`,
`n_ko`, `n_kvie`, `n_tyr`, `n_stud`, `n_kalv`,
`type`, `status`, `carrier_id`, `farmer_id`, `created_by`, `rejection_reason`,
`note`, `capacity_override`, `external_ref`, `end_time`, `period`

Dyr angives ikke som ét samlet tal, men pr. kategori (`n_ko`, `n_kvie`,
`n_tyr`, `n_stud`, `n_kalv`). `animal_count` er ikke klientstyret —
`validate_booking` sætter den til summen af kategorikolonnerne ved hver
INSERT/UPDATE, ligesom `end_time`/`period`. Den er bevidst *ikke* en
`GENERATED`-kolonne: en `BEFORE`-trigger kan ikke læse værdien af en
generated-kolonne, før den er beregnet, og kapacitetstjekket i samme
trigger har brug for summen med det samme.

<!-- UDFYLD: fulde kolonnedefinitioner og constraints -->

**Status:** `AFVENTER_GODKENDELSE` → `GODKENDT` | `AFVIST` | `ANNULLERET`
Administration opretter direkte som `GODKENDT`. Vognmænd opretter altid som
`AFVENTER_GODKENDELSE`. En afventende booking blokerer slottet.

**Type:** `PREBOOKING` og `BOOKING`. Prebooking kan bekræftes til booking;
status bevares, fordi slot og kapacitet allerede er reserveret.

### Kapacitet

Ligger i `settings`-tabellen og ændres i UI'et — **hardkod aldrig tallene**:
`max_animals_per_day`, `max_animals_per_slot`, `max_slots_per_booking`,
`slot_minutes`, `opening_time`, `closing_time`

- Kun mandag–fredag
- Helligdage lukkes via `closed_days`, fyldt af `sync_dk_holidays`.
  Store bededag er afskaffet fra 2024. 1. maj, grundlovsdag, juleaftensdag
  og nytårsaftensdag er ikke helligdage og tilføjes manuelt.
- Antal dyr afgør mindste antal slots: `ceil(dyr / max_animals_per_slot)`
- Markering hen over flere slots stopper ved første optagne eller lukkede
  slot og ved `max_slots_per_booking`
- `pending_counts_in_capacity` styrer, om afventende bookinger tæller med i
  dagsloftet
- Kun admin kan sætte `capacity_override` og dermed bryde dagsloftet

Alt dette håndhæves i `validate_booking`, ikke kun i klienten. Dagsloftet
låses med `pg_advisory_xact_lock` pr. dato, så to samtidige bookinger ikke
kan snige sig forbi.

---

## Kodekonventioner

- **Datoer må aldrig gå gennem `toISOString()`.** Alt regnes i lokal tid med
  `fmt`/`parse`. Tidszoneskift ville flytte bookinger en dag.
- Dansk i al brugervendt tekst. Datoer vises `dd-mm-åååå`.
- Al brugerinput gennem `esc()` før indsættelse i HTML.
- Ingen realtime-abonnement. Aktiv visning genindlæses hvert 60. sekund.
- Ingen afhængigheder ud over `supabase-js` fra CDN. Foreslå ikke et
  framework, en bundler eller et npm-projekt.

## Skal bygges

Landmandsdelen. Ikke besluttet endnu:

<!-- UDFYLD -->

- Login for landmænd
- Tabel for tilmeldinger: felter og kobling til `bookings`
  (flere tilmeldinger pr. booking — vognmanden fylder bilen fra flere gårde)

## Sprog

Svar på dansk.
