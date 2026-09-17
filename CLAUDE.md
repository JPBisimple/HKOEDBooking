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

Transportører er konkurrenter. Alt hvad der ikke tilhører transportøren selv, vises
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

**RLS-auto-enable slår ikke GRANT til.** Policies bestemmer kun hvilke
*rækker* en rolle må røre — rollen skal *også* have de grundlæggende
SQL-rettigheder på selve tabellen (`GRANT SELECT, INSERT, UPDATE, DELETE
ON <tabel> TO authenticated`). De eksisterende tabeller fik det ved
projektets oprindelige opsætning; en helt ny tabel oprettet via migration
gør det ikke automatisk. Mangler grant, fejler det som en RLS-afvisning
(`42501`, samme fejlkode og klientbesked som en policy-afvisning) — de
kan ikke skelnes fra UI'et. Se `booking_animals` for eksemplet.

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
- `23P01` (exclusion constraint) → dobbeltbooking af samme interval

---

## Sådan virker forretningen

### Tilmelding

Landmanden melder dyr til slagtning. To indgange, samme resultat:

1. **Landmanden selv i appen.** Han vælger transportør. Har han en foretrukken
   transportør tilknyttet, er den forudfyldt.
2. **Telefon.** Mange landmænd er teknologiforskrækkede og ringer i stedet
   til en transportør, som taster tilmeldingen ind på deres vegne.

Transportøren skal altså kunne oprette en tilmelding for en landmand, der ikke
selv bruger systemet.

Landmanden angiver en **ønsket afhentningsdato** ved tilmeldingen. Det er et
ønske, ikke en aftale — transportøren er ikke bundet af den.

**Der er ingen tilmeldingsfrist.** Først til mølle.

### Booking

Transportøren planlægger. Rækkefølgen er:

1. Han ser, hvilke slots der er ledige på slagteriet
2. Han booker afleveringstid
3. Han aftaler derefter afhentning hos landmændene

Han planlægger ruten ud fra sin egen kapacitet og sin egen geografikendskab.
Systemet beregner ikke ruter og beregner ikke transporttid. En tilmelding kan
derfor aldrig overstige bilens kapacitet — transportøren styrer det selv.

### Afhentningstidspunkt

**Transportøren indtaster dato og tidspunkt manuelt pr. tilmelding.** Systemet
udleder det ikke og beregner ikke ruter.

To adskilte felter, som aldrig må overskrive hinanden:

- **Ønsket dato** — sat af landmanden ved tilmelding. Transportøren kan ikke ændre den.
- **Aftalt dato og tidspunkt** — sat af transportøren. Tom indtil han har planlagt.

Landmanden skal kunne se begge, så han kan se, om ønsket blev imødekommet,
eller om der bare ikke er planlagt endnu.

**Transportøren giver selv landmanden besked** — telefon, SMS, uden for
systemet. Appen sender ingen notifikationer og skal ikke bygges til det.
Den er opslagsstedet, ikke beskedkanalen.

### Tilmeldingen godkendes ikke

En tilmelding har **ingen godkendelsesstatus**. Den er data, der venter på at
komme med en bil. Administrationen godkender bookinger — ikke tilmeldinger.

### Hvad transportøren må

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
| Transportør | alt andet end `admin` | Sende forespørgsler, se og annullere egne |

Rolle hentes fra `profiles` ved login. Uden profilrække nægtes adgang.
Login er e-mail + password (`signInWithPassword`).

**Landmænd er i dag data, ikke brugere.** `farmers` er en fast liste, som
transportøren vælger fra. Ingen landmandsrolle, intet landmands-UI.

### Datamodel

Tabeller: `profiles`, `bookings`, `booking_animals`, `carriers`, `farmers`, `closed_days`, `settings`
Views: `v_calendar` (maskeret kalender), `v_daily_load` (aggregeret dagsbelastning)
Funktioner: `is_admin()`, `my_carrier_id()`, `validate_booking()` (trigger),
`validate_booking_animal()` (trigger),
`sync_dk_holidays(from_year, to_year)`, `dk_holidays(y)`, `easter_sunday(y)`

Enums:
- `app_role`: `admin`, `carrier`
- `booking_status`: `AFVENTER_GODKENDELSE`, `GODKENDT`, `AFVIST`, `ANNULLERET`
- `booking_type`: `PREBOOKING`, `BOOKING`
- `animal_category`: `KO`, `KVIE`, `TYR`, `UNGTYR`, `STUD`, `KALV`

`profiles` har `carrier_id` med fremmednøgle til `carriers`, og
`chk_carrier_has_company` kræver, at en bruger med rollen `carrier` altid har
et firma. **En landmandsrolle kræver derfor både en ny `app_role`-værdi og en
måde at pege på `farmers` — profiltabellen skal udvides.** Check-constraint'en
er formuleret, så en ny rolle ikke automatisk kræver `carrier_id`.

`bookings`: `booking_date`, `start_time`, `slot_count`, `animal_count`,
`n_ko`, `n_kvie`, `n_tyr`, `n_ungtyr`, `n_stud`, `n_kalv`,
`type`, `status`, `carrier_id`, `farmer_id`, `created_by`, `rejection_reason`,
`note`, `capacity_override`, `external_ref`, `end_time`, `period`,
`driver_name`, `truck_plate`, `trailer_plate`, `arrived_at`, `picked_up_at`

Kategorierne vises i UI'et som "Ko/ungko", "Kvie", "Kalv 8-12",
"Ungtyr 12-24", "Tyr 24+" og "Stud" — aldersgrænserne er en del af
labelen, ikke et separat felt. `UNGTYR` (12-24 mdr.) er adskilt fra
`TYR` (24+ mdr.); tilføjet efter `TYR` i enum'en i migration
`20260917150000_add_ungtyr_category.sql`.

Dyr angives ikke som ét samlet tal, men pr. kategori (`n_ko`, `n_kvie`,
`n_tyr`, `n_ungtyr`, `n_stud`, `n_kalv`). `animal_count` er ikke klientstyret —
`validate_booking` sætter den til summen af kategorikolonnerne ved hver
INSERT/UPDATE, ligesom `end_time`/`period`. Den er bevidst *ikke* en
`GENERATED`-kolonne: en `BEFORE`-trigger kan ikke læse værdien af en
generated-kolonne, før den er beregnet, og kapacitetstjekket i samme
trigger har brug for summen med det samme.

`driver_name`/`truck_plate`/`trailer_plate`/`arrived_at` udfyldes af
transportøren ved afhentning (chauffør og køretøj kan variere pr. tur).
`picked_up_at` sættes når transportøren bekræfter afhentning — det låser
`booking_animals` for videre redigering (se nedenfor), uafhængigt af
`status`. "Forventet ankomst kl." er allerede `start_time`; der er ikke
brug for et separat felt til det.

#### `booking_animals` — enkeltdyr pr. booking

Aggregeret dyretal (`n_ko` osv.) er nok til selve bookingen, men CHR pr.
dyr og den lovpligtige "køreseddel" kræver data pr. enkeltdyr:
`booking_id`, `category` (`animal_category`), `eid`, `chr`, `animal_no`,
`qa_mark` (2=Standard, 3=Returdyr), `scanned_at`, `loaded_at`
(køresedlens "Læssetidspunkt"), `salmonella_status`, `remarks`, `source`
(`MANUAL`/`WAND_UPLOAD`).

Dyr/CHR kan indtastes eller indlæses af transportøren — og senere landmanden,
når landmandsdelen findes — helt frem til bookingen er afhentet.
`validate_booking_animal` blokerer al redigering, når `bookings.picked_up_at`
er sat (admin er undtaget). Det er **ikke** obligatorisk at udfylde CHR
før afhentning, men UI'et skal tydeligt markere dyr, hvor det mangler.

`category` er ikke obligatorisk: en fil fra staven kan indeholde flere
kategorier i samme upload, og kategori pr. dyr skal senere hentes fra
SEGES via API (ikke bygget endnu) i stedet for at blive valgt manuelt
ved upload. Ved manuel indtastning af ét dyr angives kategori stadig
direkte.

**To forskellige indtastningsveje ind til `chr`/`animal_no`:**

- **Manuel indtastning:** to felter, "Originalt CHR" (`chr`) og "CKR"
  (`animal_no`), plus et beregnet skrivebeskyttet "CKR-dyrenr."-felt
  (`chr`-`animal_no`). Landekoden (208) tastes aldrig — den kommer kun
  fra EID og er ikke relevant ved manuel indtastning. `chr` forudfyldes
  fra landmandens egen stamdata (`booking.farmers.chr`), da dyret
  normalt kommer fra den gård, bookingen gælder — redigerbar, hvis det
  undtagelsesvis er forkert.
- **Upload fra stav** (CSV-eksport, `EID;VID;Date;Time;QAMark`): `eid` =
  "208 005914700404" → landekode `208` (bruges ikke endnu — til
  fremtidigt SEGES-opslag) + 12-cifret krop, hvor de første 7 cifre er
  `chr` og de sidste 5 er `animal_no` ("0059147-00404" = CHR 0059147,
  dyr 00404). `VID`-kolonnen i filen er tom og bruges ikke.

`UNIQUE(eid)` — et øremærke er unikt pr. dyr, så samme EID på to
bookinger er enten en fejlscanning eller en reel fejl. Almindeligt
(ikke partielt) constraint: Postgres udelukker altid NULL fra sig selv
i et unikt indeks, så flere dyr uden EID er stadig tilladt — og kun et
almindeligt constraint kan bruges som `ON CONFLICT`-mål af
`upsert()`/PostgREST (et partielt indeks kræver, at forespørgslen
selv gentager `WHERE`-betingelsen, hvilket klientens `upsert()` ikke gør).

**Salmonellastatus hentes fra SEGES via API — ikke bygget endnu.** Feltet
står tomt indtil da; udfyldes ikke automatisk eller manuelt.

**Dyr/CHR-skærmen** (`animalsModal` i `index.html`) er lagt op efter samme
mønster som det eksterne "CattleReg"-værktøj (indtastningslinje øverst,
resultattabel nedenunder), men i appens eget mørke tema. Alder, Salmonella,
veterinær- og fødevarestatus og "Må slagtes" er kolonner i tabellen, der
viser en tom placeholder, indtil SEGES-integrationen findes — de er **ikke**
felter, der kan udfyldes manuelt. "Søg"-knappen er bevidst deaktiveret: der
findes endnu ikke et SEGES-opslag at koble den til, så den er kun visuel
forberedelse. Et "Uden check"-toggle fra CattleReg-forlægget er bevidst
fravalgt — det hører til et "med check"-flow (SEGES-opslag), som ikke skal
være en del af denne app. CSV-eksport og "Ryd alle" er lokale
hjælpefunktioner, ikke afhængige af SEGES.

**Køreseddel:** myndighedskrav. Udskrives fra `booking_animals` +
bookingens/landmandens stamdata: landmandens navn/adresse/CHR
(`farmers.chr/address/zip_code/city`), CKR-dyrenr. (`chr`-`animal_no`
pr. dyr), kategori-afkrydsning, Salmonellastatus, Læssetidspunkt,
Bemærkninger, samt køretøjsfelterne på `bookings`. Genereres som en
printvenlig visning (browserens eget `window.print()`), ingen ny
afhængighed.

`farmers` har desuden `chr`, `address`, `zip_code`, `city` til samme
formål — endnu ikke udfyldt for de eksisterende landmænd.

<!-- UDFYLD: fulde kolonnedefinitioner og constraints -->

**Status:** `AFVENTER_GODKENDELSE` → `GODKENDT` | `AFVIST` | `ANNULLERET`
Administration opretter direkte som `GODKENDT`. Transportører opretter altid som
`AFVENTER_GODKENDELSE`. En afventende booking blokerer intervallet. Vises i
UI'et som "Afventer slagteri" (`statusTxt()` i `index.html`).

**En transportørs rettelse af en godkendt booking sender den tilbage til
`AFVENTER_GODKENDELSE`.** Håndhæves i `validate_booking`: `tg_op = 'UPDATE'
and not is_adm and old.status = 'GODKENDT' and new.status = 'GODKENDT'` →
status nulstilles. Gælder enhver rettelse fra en transportør — inkl.
"Bekræft booking" (prebooking → booking), hvor status tidligere altid
blev bevaret uændret. Rammer ikke en eksplicit annullering (transportøren
sætter selv status til `ANNULLERET`), og rammer ikke admins egne
rettelser, da admin allerede har godkendelsesret.

**Type:** `PREBOOKING` og `BOOKING`. Prebooking kan bekræftes til booking;
slot og kapacitet er allerede reserveret, så selve typeskiftet kræver
ikke ny kapacitetstildeling — men status følger reglen ovenfor, hvis
bookingen var godkendt og det er en transportør, der bekræfter.

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
- Kun admin kan sætte `capacity_override` og dermed bryde både dagsloftet
  og loftet pr. interval (`max_animals_per_slot × slot_count`). Checkboksen
  i bookingformularen ("Tillad at overskride kapacitet") er kun synlig for
  admin og sætter feltet — uden den er der ingen vej til at sætte
  `capacity_override` fra UI'et.

Alt dette håndhæves i `validate_booking`, ikke kun i klienten. Dagsloftet
låses med `pg_advisory_xact_lock` pr. dato, så to samtidige bookinger ikke
kan snige sig forbi.

`slot` i skemaet (`slot_count`, `max_animals_per_slot`, `max_slots_per_booking`)
er den tekniske betegnelse i databasen. UI'et kalder det samme begreb
"interval"/"intervaller" i al brugervendt tekst — kolonnenavnene er ikke
omdøbt.

### Fysiske porte — udskudt, ikke bygget

Modtagelsen har 7 fysiske porte. Teoretisk kan der derfor modtages op til
7× kapaciteten pr. interval samtidig, hvis alle porte bruges — i dag har
systemet kun ét samlet loft pr. interval (`max_animals_per_slot`), som om
der kun var én port. Én af de 7 porte er reserveret (fx til staldkøer),
men reglen for hvilken og hvornår er ikke afklaret endnu (Henrik mangler
at fastlægge det). **Byg ikke en portmodel, før det er afklaret** — en
tildeling af booking til port, med kapacitet og dobbeltbooking-tjek
(`bookings_no_overlap`) omregnet til at være pr. port, er en større
ændring, og en forhastet regel for den reserverede port vil sandsynligvis
skulle laves om.

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
  (flere tilmeldinger pr. booking — transportøren fylder bilen fra flere gårde)

## Sprog

Svar på dansk.
