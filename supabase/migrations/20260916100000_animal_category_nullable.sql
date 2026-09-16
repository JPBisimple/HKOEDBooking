-- Kategorien kendes ikke ved upload fra stav — én fil kan indeholde flere
-- kategorier ad gangen. Kategori pr. dyr skal senere hentes fra SEGES via
-- API (ikke bygget endnu); indtil da står den tom for dyr fra en
-- stav-upload. Ved manuel indtastning angives kategori stadig direkte.

alter table public.booking_animals alter column category drop not null;
