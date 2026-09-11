# Crown Nemesis — project status

**Last updated:** 2026-09-11
**Read this first if you are a fresh Claude session picking up this project.**

This file is the handoff document. It is the canonical one — it lives in the
repo and is versioned with the code. Keep it current: when you finish a chunk
of work, update the "Where things stand" and "Backlog" sections before the
session ends.

---

## 1. What this is

A competitive 1v1 turn-based tactics card game.

| | |
|---|---|
| Live | https://jaredartt.github.io/tactica/ |
| Repo | `github.com/jaredartt/tactica` (branch `main`) |
| Front end | React 18 + TypeScript + Vite, no UI framework, hand-written CSS |
| Back end | Supabase (Postgres + RLS + Realtime + Auth) |
| Deploy | GitHub Pages, via `./deploy.sh` |
| Owner | Jared (jaredartt@gmail.com) — solo dev, also draws all the art |

### Architecture in one paragraph

**The server is the authority.** There is no INSERT/UPDATE/DELETE policy on
`matches`. Every mutation goes through a `SECURITY DEFINER` plpgsql function.
The client is a renderer that calls RPCs. This is deliberate and must not be
eroded — if you find yourself wanting the client to compute a game outcome,
you are about to introduce a cheat.

Rules and authorisation are split: `cn_move` / `cn_attack` hold the rules and
take an explicit `p_side`; `submit_move` / `submit_attack` are thin shells that
work out who you are and call them. **The bot calls the same `cn_*` functions**,
so it is bound by every rule a player is, and a rule change moves it too.

---

## 2. How to work on this repo

### Where the files are

The work happens **on Jared's machine**, through the device bridge, at:

```
$HOME/mnt/Documents/tactica          # via mcp__remote-devices__device_bash
```

Edit files there in place with `device_bash` (python read-modify-write, or
`sed -i`). **Never re-type a file's contents from earlier tool output** — it may
have been truncated. Only stage files into the cloud container when you need
the Postgres harness or Playwright.

### Deploy

```bash
cd ~/Documents/tactica
TACTICA_REMOTE="https://x-access-token:$(cat ~/.ghtok)@github.com/jaredartt/tactica.git" ./deploy.sh
```

`deploy.sh` builds to a `mktemp -d` on purpose: Vite cannot unlink stale assets
inside the synced folder. For a plain type/build check use:

```bash
npx tsc -b && npx vite build --outDir "$(mktemp -d)" --emptyOutDir
```

### The git lock dance

`rm` fails inside the synced Documents folder, so git's lock files cannot be
removed normally. Before **every** git command:

```bash
mkdir -p .git/_stale && mv .git/*.lock .git/_stale/ 2>/dev/null
```

Files you need to delete go to `_to_delete/` (already gitignored) — or ask for
delete permission via `device_request_delete_permission`.

### The SQL test harness (cloud container)

```bash
export PGBIN=/usr/lib/postgresql/16/bin
su pg -c "$PGBIN/pg_ctl -D /home/claude/pgdata -o \"-k /home/claude/pgsock -p 5455 -c listen_addresses=''\" -l /tmp/pg.log -w start"
cd /home/claude/cn && ./t.sh 01_rules.sql 02_presence.sql 03_ladder.sql 04_roster.sql \
                             05_idle.sql 06_bot_ranked.sql 07_abilities.sql 08_profile.sql
```

`sync.sh` copies staged migrations/tests in; `reset.sh` rebuilds the database.
Postgres must run as the `pg` user, not root. Stage files first with
`device_stage_files` so `/mnt/user-data/uploads/Documents/tactica/...` is fresh.

**Current: 336 assertions, all green.** `09_combat.sql` is the Phase A file.

Parry and crit are 5% rolls, so the suite pins them the way it pins the coin
flip: `cn.force_parry` and `cn.force_crit` are set to `'never'` on the test
database in `_helpers.sql`, and a section that wants one turns it on with
`set cn.force_parry = 'always'` and resets it after. A unit at 0% or 100% is
not rolling at all, so the hatch does not reach it -- that is how one test
stands a non-parrying unit up in a forced-parry board.

### The one rule that matters most

> **Verify by measurement, not by eye.**

Every layout or visual claim gets checked in headless Chromium
(`/opt/pw-browsers/chromium`) with real numbers — element rects, computed
styles, `elementFromPoint`. Two of the worst bugs in this project's history
(the board collapsing to zero height, the unit info box shoving the map) were
invisible to reasoning and obvious to a measurement. Where a bug is subtle,
write the test so it **fails on the old code first** — a test that passes on
both versions proves nothing.

### Security constraints (non-negotiable)

- **Never** handle or enter the Supabase database password.
- **Never** put a `service_role` or secret key in `.env.local` or the repo. The
  `sb_publishable_` anon key is public by design and is fine.
- Do not create accounts or enter passwords on Jared's behalf.
- Jared has given blanket consent for GitHub operations and for using his
  computer. You do not need to ask before pushing or committing.

---

## 3. Where things stand

### Shipped and live

Profile icons + settings panel, UI sounds, reduce-motion, battle sound effects
(11 synthesised sounds — WebAudio, no files), plus everything before that.

### Committed locally but NOT pushed

**`afc4f7f` — "Quick fixes: the blank rematch page, a top bar that stays, and
the roster"**

GitHub was unreachable from the device sandbox (proxy 403 on every attempt,
after having worked earlier the same session). Retry the deploy command above.
It contains:

- **The blank white page on practice rematch — fixed.** Not a crash. Match's
  navigation effect depended on `onGoTo`, which App rebuilt every render, so it
  re-ran every render — and Match re-renders 5×/second off its own clock. Each
  run restarted the wipe, whose swap lands at 310ms, so the swap never ran: the
  white block covered the screen forever. Three independent fixes (stable
  `useCallback` identities, a `wentTo` ref, and `cross()` no longer restarting
  its clock). Regression test reproduces the old failure and passes on the new.
- Top bar (`CROWN NEMESIS` + avatar + name + gear) fixed above all menu layers,
  visible and **interactive** inside every section. Height is `--head-h`.
- My Team → **My Kingdom**. Hover panel now covers the whole rhomboid
  (`inset: 0 -17%` to match the counter-skew). No more phantom all-hovered grid
  on mobile.
- Tokens: blue halo gone; rim is black on both sides and drawn as an **inset
  shadow** rather than a border (that is what closed the white corner slivers —
  a real border gives the art a different inner radius); `border-radius: 11%`;
  no tilt on hover. Move tiles pulse, no centre dot.
- Face picker: captions removed, avatars 80px.
- PWA icon grey gradient: `background_color`/`theme_color` were **already**
  `#ffffff`, so that was not the cause. Chrome had no `maskable` icon and the
  PNGs carry transparency, so it composited them onto its own background. Added
  opaque `icon-maskable-512/192.png` with the mark inside the centre 78%.

### Migrations

`0001`–`0016` and **`0018_combat_core.sql`** are applied in production —
Jared ran `0018` on 2026-09-11.

**`0017_first_move_coin.sql` is still unconfirmed.** It was never reported as
run, and `0018` does not depend on it (`0018` never touches `cn_set_ready`), so
running them out of order changed nothing — but until `0017` is in, the host
still moves first in every mode. Check `cn_set_ready` in the SQL editor before
assuming either way.

`0017` makes who moves first a coin flip in **every** mode (was: host always
first; `0012` only randomised the ranked *seat*). It is spliced from `0008`
rather than rewritten, because `cn_set_ready` is what turns two hidden
half-boards into one live game. `cn.first_side` is the test escape hatch,
pinned per-database in `_helpers.sql`. Measured fair: 149/300.

---

## 4. Decisions already made (do not re-litigate)

| Question | Answer |
|---|---|
| Turn structure | **Pokémon-style.** Player A plays, then player B, and *that* is one turn. `turnNumber` increments after both have played. |
| Counters | Only when the defender **can reach the attacker**. A Range 3 mage shooting from 3 tiles takes no counter from a Range 1 knight. |
| Range shape | **Everything within N tiles, Chebyshev** (diagonals count as 1). Range 2 = every tile 1–2 away, corners included. Single number, no more min–max spans. |
| Build order | Quick fixes → battle rewrite → Fire Emblem animation layer → i18n + dark mode + kingdoms → tournaments last. |
| Translations | **Split.** UI strings in repo JSON (versioned, zero DB reads, code-splittable). Card ability text in the **database** — otherwise every balance tweak needs a deploy, which defeats the live card editor. |
| Card art hosting | **Supabase Storage**, uploaded from the admin panel. Not GitHub-direct: that needs a write token in a public client bundle. Store the **full URL** in `cards.art_url` / `cards.token_url`, never a bare filename — then switching hosts later is a column update, not a rewrite. |
| Deleting cards | **Retire** (`is_active = false`), not hard delete. `deck_of()` already falls back for retired cards, and a real delete would orphan finished matches. |
| Altea Twins | **Dropped for now.** No stat block was ever provided. |
| Battlefield background art | **Dropped for now.** Never attached. |

### Art already identified

- Braided girl in white → **Dorme**
- Crowned figure (pink line art) → **King Stelaris**
- Black-and-white flame character → **the placeholder** (for Velmor, Sarrave, Thalgrim, Nyxara, Zephyra, etc.)
- Effect icons: blue shield = **Defend**, gold sparkles = **Stunned**, purple spiral = **Poisoned**, red = **Burned**

---

## 5. Backlog — the big battle rework

Jared's spec. Phased in the agreed order. **Nothing below is started.**

### Phase A — combat core (SQL) — **DONE, in `0018_combat_core.sql`**

Built, tested (`09_combat.sql`), and waiting to be pasted into the Supabase SQL
editor. Not yet run in production. What it does:

- Counter **always** happens when attacked and the defender can reach back,
  for **50%** of the counter-attacker's roll. Halving it is what let it become
  automatic: trading blows is now the normal shape of a fight rather than a
  punishment for attacking into reach.
- **5% parry** on any attack: blocks it completely, then answers for 50% if the
  parrier can reach what it caught. Parries chain, **capped at 8 swings**
  (`cn_parry_cap()`), which is the only thing that can reach the cap.
- **5% crit**, +50%, on attacks, counters, and post-parry counters.
- Passives cannot be parried. Lium's answer-first is a passive and lands
  through a parry for that reason.
- Damage is a **single number ±5**: `cards.power` is the stat, `dmin`/`dmax`
  are derived from it and are now just the dice. The client prints the single
  number via `unitPower()`, which falls back to the middle of the old band for
  a match that was already in flight when this landed.
- Heals never crit, are never parried, never draw a counter.
- **Damage order**, confirmed by Jared and implemented once in `cn_damage()`:
  base roll → ×1.5 crit → ×0.5 counter → ×(1 + attacker bonuses) →
  ×(1 − defender resists) → ×0.5 if defending → round. Bonuses multiply before
  resists so a 20% bonus and a 20% resist do not cancel exactly. `p_bonus`,
  `p_resist` and `p_defending` are the hooks Phase B and the royal passives
  hang on — nothing passes anything but zero yet.
- **Losing your royal loses the match**, with four of your units still
  standing if that is how it falls.
- **Exactly one royal per kingdom** (Jared's answer), enforced in `set_deck`,
  and `deck_of` falls back to the default for a deck saved before the rule
  existed. `random_deck()` draws the bot's five under the same rule.

Left for the roster rework, and deliberately: **Dereo is the only royal on the
board**, so "exactly one" is a forced pick today. Queen Miah and King Stelaris
need art before they can be added, and the rule had to exist first or every
deck saved in the meantime would be illegal the day they land. Lium keeps his
old answer-first passive *and* gains the doubled rates and parries-all-parries
the spec gives him; the roster rework should split those apart and move
answer-first to Dorme, where it belongs.

### Phase B — turn and board

- 2 unit-actions per turn. Exception: the very first player's very first turn is
  1 unit only.
- "End turn" available at any time.
- Board → **8 tall × 6 wide** (currently 6×6, set in `cn_fresh_map`, `v_w`/`v_h`).
- **4 trees per side** (currently 3). No trees in the board corners, none in the
  row nearest each player's edge.
- **Back to top/bottom sides, chess.com style** — board flips per player. You
  are always at the bottom, yours always blue, theirs always red at the top.
  (This reverts the left/right change from `0011_sides.sql`.)
- Fire Emblem action menu on clicking a unit: Move / Attack / Ability / Defend /
  Cancel.
- **Defend**: halves incoming damage, costs one of your two actions.
- Movement arrow from unit to hovered tile, Fire Emblem style.
- **Duelyst-style opponent presence**: show which tile the opponent is hovering,
  and their targeting highlights while they aim. Hidden for Rogue secret actions.

### Phase C — the battle cinematic

- Fire Emblem 1v1: both units enlarge and float with slow tilts, attacker
  charges, clash/parry/counter/heal effects, HP bars beneath each.
- Animated black caption boxes narrating damage, reductions, and which passive
  fired and why.
- **Hitstop on every attack.** Camera shake on crits and parries.
- Parry VFX modelled on Super Smash Bros Ultimate.
- Per-ability animations (fireball travels, etc.) and status-effect animations.

### Phase D — UI, i18n, kingdoms

- **Dark mode**: follows system theme, plus an explicit light/dark toggle.
- **All settings saved per account** (currently localStorage) → `profiles.settings`
  jsonb, localStorage as cache.
- **Spanish** translation toggle. UI strings in repo JSON; ability text in DB
  (`ability_en` / `ability_es`). Jared supplies the ability translations.
- **Kingdoms**: up to 10 saved decks, renameable, each with a unit-token icon.
  Selected kingdom is used in every mode. A "change kingdom" affordance in a
  corner of every pre-battle screen.
- Hover card: all info **outside** the art (above and below), so hovered cards
  are no longer square.
- Clicked unit → zoomed card **locks to the left** so you can read it without
  hovering.
- Zoomed card: slow float + slow rotate + slow random tilt on hover; snaps to a
  static reset view on click.
- Keyword tooltips: vague words ("slightly", "Burn", "Critical hit") render in
  **purple**; hovering shows a small speech bubble with the real number.
- **Long-press on mobile** shows the zoomed card.
- Effect icons at the **upper-left** of a token, stacking rightward as more
  apply, disappearing with the effect.
- Deployment: you can see **which units** the opponent picked (but not where
  they place them).
- Match start: black box, white text, "Defeat the king." in epic motion.
- Admin card editor (Jared's account only): create / edit / **retire** cards,
  upload token + full art to Supabase Storage. Add `profiles.is_admin` + an RLS
  UPDATE policy on `cards`. In-flight matches keep their snapshot because units
  are copied into `matches.state` at deploy — that is correct, not a bug.
- Ladder: new **tournaments** stat; show everyone's avatar.

### Phase E — tournaments (its own project)

Friday Tournaments menu tile, bottom-rightmost. Bracket that sizes itself to
the entrant count, spectating any live match in the tournament, winners wait in
a "waiting" state, leaving counts as a loss and advances the nearest-bracket
winner. Open every day for now; Friday-only later.

### Status effects to build

| Effect | Behaviour |
|---|---|
| Burned | Loses 15% HP each time the unit attacks or uses its ability (not its passive) |
| Poisoned | Loses 10% HP each turn |
| Stunned | Cannot attack for a turn |
| Defend | Not an effect, but shares the icon slot: halves incoming damage this turn |

---

## 6. The roster spec

**Classes:** Royal · Rogue · Knight · Mage · Flying
(ES: Realeza · Furtivo · Caballero · Mago · Volador)

Text in parentheses is the **tooltip number**, not part of the description —
the word immediately before it is the purple keyword.

| Unit | Class | HP | DMG | MOV | RNG | Ability / Passive |
|---|---|---|---|---|---|---|
| King Dereo | Royal | 110 | 30 | 1 | 1 | **A:** Grants the team minor (20%) resistance to Knights. |
| Queen Miah | Royal | 110 | 25 | 1 | 1 | **A:** The entire team deals slightly (20%) more damage to Mages. |
| King Stelaris | Royal | 120 | 30 | 1 | 1 | **A:** Grants the team strong (50%) resistance to burn and poison. |
| Dione & Grifo | Knight | 95 | 30 | 1 | 1 | **A:** Back to Back — Deals 15 damage to all nearby (Range 1) tiles. |
| Lium | Knight | 85 | 35 | 1 | 1 | **P:** Always Ready — Slightly (5%→10%) increased parry and crit rates. Parries all parries. |
| Mako | Rogue | 60 | 35 | 2 | 1 | **A:** Improvised Trap — Plants a hidden bomb dealing 15 damage. Can plant another if destroyed. |
| Eva | Rogue | 80 | 20 | 2 | 2 | **A:** Nature's Whisper — Summons Mist for 2 turns. Allied Rogues are invisible. |
| Himanta | Rogue | 70 | 25 | 2 | 1 | **P:** Slippery — Immune to parries and crits. Slight (25%) chance to strike twice. |
| Dorme | Rogue | 65 | 30 | 2 | 2 | **P:** Quick Dagger — Always counters before the attacker's hit lands. |
| Fey | Mage | 85 | 15 | 2 | 3 | **A:** Cursed Wall — Summons an underworld wall with 20 HP. Can resummon if destroyed. |
| Umiro | Mage | 75 | 25 | 1 | 2 | **P:** Swamp Bringer — Nearby units cannot use Passives or Abilities. |
| Sinie | Mage | 65 | 30 | 2 | 3 | **A:** Healing Petals — Heals 30 HP to a target. |
| Ashvar | Mage | 70 | 20 | 2 | 2 | **A:** Fireball — Burns 2 tiles in a line and deals them 15 damage. |
| Velmor | Mage | 70 | 35 | 2 | 2 | **A:** Cursed Blade — Poisons the target and deals 10 damage. |
| Sarrave | Mage | 80 | 15 | 1 | 1 | **P:** At the start of their turn, poisons all adjacent tiles. |
| Thalgrim | Mage | 80 | 15 | 1 | 1 | **P:** Deals an extra 25 damage if the target is poisoned. |
| Nyxara | Mage | 65 | 15 | 2 | 2 | **P:** Cursed Body — Heals for 100% of damage dealt. |
| Wuzu | Flying | 85 | 25 | 3 | 2 | **P:** Regenerative Body — Heals slightly (5%) every turn. |
| Lumea | Flying | 75 | 20 | 4 | 2 | **A:** Gale Summoner — Creates a tornado. If stepped on, choose where to throw them (15s limit). |
| Zephyra | Flying | 65 | 20 | 4 | 1 | **P:** Cyclone — Stuns the target on hit. |

### Spanish ability text

| Unit | ES |
|---|---|
| King Dereo | Otorga al equipo una leve (20%) resistencia contra Caballeros. |
| Queen Miah | Todo el equipo inflige un leve (20%) daño adicional a Magos. |
| King Stelaris | Otorga al equipo gran (50%) resistencia a quemadura y veneno. |
| Dione & Grifo | Espalda con Espalda — Inflige 15 de daño a todas las casillas de alrededor (Rango 1). |
| Lium | Siempre Atento — Probabilidad de bloqueo y crítico levemente (De 5% a 10%) aumentada. Bloquea todos los bloqueos. |
| Mako | Trampa Improvisada — Planta una bomba oculta de 15 de daño. Puede plantar otra si esta se destruye. |
| Eva | Susurro Natural — Invoca Niebla por 2 turnos. Los aliados Furtivos son invisibles dentro. |
| Himanta | Escurridizo — Inmune a bloqueos y críticos. Leve probabilidad (25%) de atacar dos veces. |
| Dorme | Daga Rápida — Siempre contraataca antes de recibir el golpe. |
| Fey | Muro Maldito — Invoca un muro con 20 PV. Puede volver a invocarlo si es destruido. |
| Umiro | Portador del Pantano — Las unidades cercanas no pueden usar Pasivas ni Habilidades. |
| Sinie | Pétalos Curativos — Cura 30 PV a un objetivo. |
| Ashvar | Bola de Fuego — Quema 2 casillas en línea y les inflige 15 de daño. |
| Velmor | Espada Maldita — Envenena al objetivo e inflige 10 de daño. |
| Sarrave | Al inicio de su turno, envenena todas las casillas adyacentes. |
| Thalgrim | Inflige 25 de daño adicional si el objetivo está envenenado. |
| Nyxara | Cuerpo Maldito — Se cura el 100% del daño infligido. |
| Wuzu | Cuerpo Regenerativo — Se cura levemente (5%) cada turno. |
| Lumea | Invocador de Vendavales — Crea un tornado. Si una unidad entra, elige a dónde lanzarlo (límite 15s). |
| Zephyra | Ciclón — Aturde al objetivo al golpearlo. |

### Rules notes attached to the roster

- **Mist** makes allied Rogues invisible to the opponent. Players must always be
  able to attack empty tiles, so invisible units can be guessed at. A hit
  invisible unit becomes visible: *"[name] was discovered in the Mist!"*. Attacking
  while invisible also reveals.
- **Summons** (tornado, wall, trap) are placed within the summoner's Range.
- **Lumea's tornado**: only when an *opponent* unit steps in does Lumea's
  controller get 15 seconds to choose where to throw it.
- The six units that had no name (Mage A–E, Flying A) are now Ashvar, Velmor,
  Sarrave, Thalgrim, Nyxara and Zephyra. They still use the placeholder art.

---

## 7. Conventions and gotchas

### Code style

Comments explain **why**, not what, and are written as prose. Where a number is
load-bearing (an animation delay matching a CSS keyframe, a safe-zone
percentage), the comment says where the other half lives so the two move
together. Match the existing voice — it is consistent throughout.

### Things that have bitten before

- **Never cut a CSS range by searching for a stop selector** without reading
  what lies between. Doing this once swallowed a `@media` opener and left a
  stray `}`; Chromium's error recovery then ate `.match { height: 100dvh }` and
  the board vanished in every mode.
- **Counter-skewed elements need horizontal overscale.** A `skewX(8deg)` box of
  height H hides `H·tan8` of its width at each edge. `.rtile-art`, `.rtile-info`
  and `.mtile-art` all carry this; anything new that counter-skews will need it.
- **Postgres will not let you rename an input parameter** with
  `create or replace`. Drop the function and create it (this is why
  `cn_own_half` became `cn_own_side`).
- `cmin` / `cmax` are Postgres system column names. Counter reach is stored as
  `crmin` / `crmax`.
- **Splice, never rewrite from memory.** `deploy_unit` silently lost its swap
  behaviour once because it was reconstructed rather than copied from the
  previous migration and edited.
- FLIP animation is driven by **board coordinates and tile pitch**, never screen
  rects — anything that changes page height would otherwise slide the whole army.
- `useMatch` keeps the old row briefly when `matchId` changes; renders must
  tolerate a stale match for one tick.

### Keeping token cost down (Jared asked about this)

Attached images are re-sent **every turn** for the rest of a session — ten
images is ~11k tokens per turn, which dwarfs even a very long written spec.
So:

1. **Art goes in the repo, not the chat.** Drop files into `public/cards/` and
   name them in the message. Claude reads the file only if it needs to look.
2. **Long specs go in a file too** — this one, or `docs/`. "roster.md is
   updated" costs ~20 tokens; re-pasting the roster costs ~2,000 every turn.
3. Jared's prose is cheap and high-value. Don't ask him to write less.

---

## 8. Still open — ask Jared

1. ~~Damage multiplication order.~~ Confirmed: the proposal in Phase A, built.
2. ~~Parry-chain recursion cap.~~ Confirmed: 8, `cn_parry_cap()`.
3. ~~Exactly one royal per kingdom, or at least one?~~ **Exactly one.** Built.
4. ~~Real names for Mage A–E and Flying A?~~ Invented: Ashvar, Velmor, Sarrave,
   Thalgrim, Nyxara, Zephyra. The roster in section 6 uses them.
5. ~~Forest battlefield background.~~ Dropped — not wanted for now.

Nothing is open. The next thing to ask about is Phase B.
