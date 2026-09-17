-- Ny dyrekategori: Ungtyr (12-24 mdr.), adskilt fra Tyr (24+ mdr.).
-- Egen migration, fordi en ny enum-værdi ikke kan bruges i samme
-- transaktion, den bliver oprettet i.
alter type public.animal_category add value 'UNGTYR' after 'TYR';
