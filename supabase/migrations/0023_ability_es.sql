-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0022 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0023 - ability text, in two languages
--
--  The UI's words live in the repo as JSON. An ABILITY's words do not, and the
--  reason is the live card editor the admin panel is meant to become: a
--  balance tweak rewrites an ability every time, and text in the repo would
--  make every tweak a deploy. So ability_es joins ability, and the client
--  falls back to English whenever the Spanish is null -- a card whose
--  translation has not been written is still a card somebody is about to put
--  on a board.
--
--  There is no ability_en. `ability` IS the English one and has been since
--  0005; renaming a column that cn_army, deck_of and random_deck all read, to
--  gain a suffix, would be a migration that can only break things.
--
--  THE TEXT ITSELF IS REPLACED, NOT TRANSLATED.
--
--  Both columns below are set from the roster spec in project_status.md
--  section 6 -- Jared's own English and Spanish, extracted from that file
--  rather than retyped, with only the **A:** / **P:** markers stripped (they
--  say whether a thing is an Ability or a Passive, the Spanish table carries
--  no equivalent, and leaving them in would have the two languages saying
--  different amounts).
--
--  That REPLACES the prose these cards have carried since 0005, which
--  described what the engine actually does today ("Answers a blow from one
--  tile away or from two"). The spec describes what each unit is DESIGNED to
--  do, and most of those abilities are not built yet -- Dione & Grifo does not
--  deal 15 to everything nearby, Mako plants no bomb. So from this migration
--  until the roster rework, a card's text is a promise rather than a
--  description. That is deliberate and it is Jared's call; it is written down
--  here so that nobody reads it later as a bug.
--
--  The numbers in parentheses are kept. The spec calls them tooltip numbers
--  rather than part of the sentence, and Phase D's purple keyword tooltips
--  will lift them out -- until then, inline is where the information is.
-- ===========================================================================

alter table public.cards add column if not exists ability_es text;

-- ---------------------------------------------------------------------------
-- the eleven that exist. The other nine in the spec have no card row yet and
-- arrive with the roster rework.
-- ---------------------------------------------------------------------------
-- King Dereo
update public.cards set ability = 'Grants the team minor (20%) resistance to Knights.', ability_es = 'Otorga al equipo una leve (20%) resistencia contra Caballeros.' where slug = 'dereo';

-- Dione & Grifo
update public.cards set ability = 'Back to Back — Deals 15 damage to all nearby (Range 1) tiles.', ability_es = 'Espalda con Espalda — Inflige 15 de daño a todas las casillas de alrededor (Rango 1).' where slug = 'dione-grifo';

-- Lium
update public.cards set ability = 'Always Ready — Slightly (5%→10%) increased parry and crit rates. Parries all parries.', ability_es = 'Siempre Atento — Probabilidad de bloqueo y crítico levemente (De 5% a 10%) aumentada. Bloquea todos los bloqueos.' where slug = 'lium';

-- Mako
update public.cards set ability = 'Improvised Trap — Plants a hidden bomb dealing 15 damage. Can plant another if destroyed.', ability_es = 'Trampa Improvisada — Planta una bomba oculta de 15 de daño. Puede plantar otra si esta se destruye.' where slug = 'mako';

-- Eva
update public.cards set ability = 'Nature''s Whisper — Summons Mist for 2 turns. Allied Rogues are invisible.', ability_es = 'Susurro Natural — Invoca Niebla por 2 turnos. Los aliados Furtivos son invisibles dentro.' where slug = 'eva';

-- Himanta
update public.cards set ability = 'Slippery — Immune to parries and crits. Slight (25%) chance to strike twice.', ability_es = 'Escurridizo — Inmune a bloqueos y críticos. Leve probabilidad (25%) de atacar dos veces.' where slug = 'himanta';

-- Fey
update public.cards set ability = 'Cursed Wall — Summons an underworld wall with 20 HP. Can resummon if destroyed.', ability_es = 'Muro Maldito — Invoca un muro con 20 PV. Puede volver a invocarlo si es destruido.' where slug = 'fey';

-- Umiro
update public.cards set ability = 'Swamp Bringer — Nearby units cannot use Passives or Abilities.', ability_es = 'Portador del Pantano — Las unidades cercanas no pueden usar Pasivas ni Habilidades.' where slug = 'umiro';

-- Sinie
update public.cards set ability = 'Healing Petals — Heals 30 HP to a target.', ability_es = 'Pétalos Curativos — Cura 30 PV a un objetivo.' where slug = 'sinie';

-- Wuzu
update public.cards set ability = 'Regenerative Body — Heals slightly (5%) every turn.', ability_es = 'Cuerpo Regenerativo — Se cura levemente (5%) cada turno.' where slug = 'wuzu';

-- Lumea
update public.cards set ability = 'Gale Summoner — Creates a tornado. If stepped on, choose where to throw them (15s limit).', ability_es = 'Invocador de Vendavales — Crea un tornado. Si una unidad entra, elige a dónde lanzarlo (límite 15s).' where slug = 'lumea';

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='cards' and column_name='ability_es') = 1
                                                          as cards_have_spanish,
  (select count(*) from public.cards where is_active and ability_es is null) = 0
                                                          as every_live_card_has_it,
  (select count(*) from public.cards where is_active and coalesce(ability,'') = '') = 0
                                                          as and_english_too,
  (select ability_es from public.cards where slug = 'lium')
    like 'Siempre Atento%'                               as lium_reads_right;
