-- booking_animals er den første helt nye tabel oprettet via en almindelig
-- migration i dette projekt — de øvrige tabeller fik deres GRANT ved
-- projektets oprindelige opsætning. RLS-policies alene giver ikke adgang;
-- rollen skal også have de grundlæggende SQL-rettigheder på tabellen.
-- (idempotent, ufarlig at køre igen)

grant select, insert, update, delete on public.booking_animals to authenticated;
