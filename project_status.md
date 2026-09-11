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

**Current: 461 assertions, all green.** `09_combat.sql` is the Phase A file;
`10_board.sql` is Phase B's, `11_swings.sql` and `12_clock.sql` are
Phase C's, and `13_settings.sql` is Phase D's. Run the whole thing with `./supabase/tests/run.sh`.

That script has now had **three** silent-failure bugs, which is worth saying out
loud: if a test run ever looks too quiet, suspect the runner before you suspect
the tests.

1. It created no database while `_helpers.sql` pinned its GUCs with
   `alter database t`, and every psql sent stderr to /dev/null -- so the run
   died with no message at all.
2. It globbed `0[1-9]*`, which would have skipped `10_board.sql` without a
   word, and a skipped file looks exactly like a passing one.
3. The capture line had no `|| true`. With `set -e` and `pipefail`, psql
   exiting non-zero on the first failed assertion killed the script *inside the
   command substitution* -- before the `echo` that prints what it captured. A
   failing file printed its own name and then nothing, and the run ended with
   no verdict. This is how `12_clock.sql` appeared to contain no assertions
   while it was in fact failing one. Fixed.

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

### Measuring the client (Playwright)

npm cannot reach the registry from the cloud container (403 on
`registry.npmjs.org`) and Chromium is not on the device, so neither machine can
do this alone. The arrangement that works:

1. Build a harness **on the device**, where `node_modules` already is. A harness
   is an entry that mounts one component with a fabricated `MatchState`.
2. Stage the built html/js/css into the container, serve them with
   `python3 -m http.server`, and drive it with python Playwright against
   `/opt/pw-browsers/chromium-1194/chrome-linux/chrome` -- note the version in
   that path, there is no plain `chromium/` directory.
3. Measure PIXELS: element rects and the board's own tile pitch, never the grid
   styles the component wrote, because the style is the thing under test.

#### Build it WITHOUT a bundler -- `_to_delete/h/mksite.py`

Do not rely on `vite build` for a harness. `node_modules` is inside the synced
folder and therefore **shared between a Mac and a Linux VM**, while rollup and
esbuild each ship a native binary per platform. An `npm install` run on the Mac
prunes it to darwin binaries, and the VM can then run neither -- `Cannot find
module '@rollup/rollup-linux-arm64-gnu'`, and `Exec format error` from esbuild.
This has happened once already and will happen again on any `npm install`.

`tsc` is pure JavaScript and always works, so the harness is built from tsc
output instead. `_to_delete/h/mksite.py` (gone with `_to_delete`; rebuild it
from this description) does three small jobs:

1. tsc emits `from '../lib/cine'`; a browser needs `../lib/cine.js`.
2. tsc emits `import '../styles.css'`, which is not a module -- strip it and
   `<link>` the stylesheet in the page. Also replace `import.meta.env.BASE_URL`,
   which is Vite's and undefined anywhere else.
3. `react`, `react/jsx-runtime` and `react-dom/client` are bare specifiers. Load
   React's UMD builds from `node_modules/react*/umd/` as plain scripts and point
   an **import map** at three shims that re-export the globals. Read the shim's
   export list off the installed React with
   `node -e "Object.keys(require('react'))"` rather than writing it by hand -- a
   hand-written list is wrong the first time a dependency imports a hook nobody
   thought of, which is exactly how it failed once, on `useSyncExternalStore`.

To restore the native binaries instead, on the Mac:
`npm install --no-save --force @rollup/rollup-linux-arm64-gnu@$(node -p "require('rollup/package.json').version") @esbuild/linux-arm64@$(node -p "require('esbuild/package.json').version")`.
`--force` is needed because npm's `--cpu`/`--os` filter dependencies but still
platform-check a package you name directly.

Phase C's client was checked with 85 browser assertions (the takeover, the
beats and their captions, the reductions that are named and the ones that are
not, a parry chain where every flash has to be a fresh element, the falling,
skipping, phone widths, reduce-motion, and the queue and the bot hold from
inside `Board`) plus 400 random fights in node. Note that most of it is NEW
surface, so "run it against the old code first" does not apply the way it did
in Phase B -- there was nothing there to regress.

Phase B's client was checked this way -- 109 browser assertions over the flip,
the tints, the half line, the whole menu flow, the budget gates, the pips, the
movement arrow and the opponent's ghost, at 320 / 390 / 768 / 1280 px. Every one
was also run against the previous commit's files first, where they fail. That is
the only thing that proves they are testing anything.

**Not everything needs a browser.** Two things were better checked in node, by
bundling a test with the local esbuild (`node_modules/.bin/esbuild x.ts --bundle
--platform=node --format=cjs`; anything that reaches `supabase.ts` needs
`--define:import.meta.env='{...}'` or it dies on a missing env var at import):

- `pathTo()` against `reachable()` over 400 random boards, 19,200 tiles: every
  route starts on the unit, ends on the tile, steps one square at a time, and
  stands only on tiles `reachable()` agrees with. This is the check that keeps
  the arrow honest.
- The ghost's throttle, on a hand-cranked clock. Worth doing: reading it back
  is what found a real bug, where the dedupe key was stringified WITH the side
  attached on one side of the comparison and without it on the other, so the
  two never matched and every pointer move went down the wire. The rate limiter
  is now `throttler()`, exported from `useGhost.ts` with its clock and its
  timers injected, precisely so it can be tested without a browser.

The harnesses lived in `_to_delete/` and are gone; the recipes above are what to
rebuild them from.

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

### Pushed and live

`afc4f7f`, `c93311a`, `595b32d`, `4c80f8f`, `c74c47d`, `6e0d9b0` are on
`origin/main`. Jared pushed the last two himself on 2026-09-11.

**Pushing from a session is still blocked, and the shape of the block has
changed.** The cloud container can now READ the repo -- `git ls-remote` and
`git clone` over HTTPS both work -- but a push is refused by the git proxy with
`jaredartt/tactica is not in this session's authorized repository set`. That is
a policy denial and not a credentials problem: the repo is rejected before any
credential is read, so it lands identically with a token and with none. The
device sandbox still gets a proxy 403 on CONNECT and cannot reach GitHub at all.
Two tokens were pasted into chat in earlier sessions trying to solve this and
neither could; both should be treated as burned and rotated.

So the working arrangement is: a session commits, Jared pushes. To lift it, add
the repo to the session's sources. (A session CAN move a commit to where Jared
can push it without going through GitHub: `git bundle create` on the device,
stage the bundle, fetch it in the container. That is how `c74c47d` was checked
against origin.)

**Still not deployed.** `./deploy.sh` force-pushes `gh-pages` and hits the same
wall, so it has to be run from an ordinary terminal.

### What those four commits contain

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

`0001`–`0018` are applied in production. Jared ran `0017` and `0018` on
2026-09-11, so the coin flip below is live and the host no longer always opens.

`0019_board_and_actions.sql` is **run in production** as of 2026-09-11, so the
8-tall board, the two-activation turn, Defend and Wait are all live.

`0020_swings.sql` and `0021_cinematic_clock.sql` are **run in production** as of
2026-09-11, so the blow-by-blow record and the paused turn clock are both live.

**`0022_settings.sql` is built and tested but NOT yet run in production.** It is
Phase D's first piece -- see the Phase D section.

`0017` is confirmed run, so who opens is now a coin flip in every mode.

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

**Phase B is DONE, both halves.** The server half is `0019_board_and_actions.sql`
(`10_board.sql`, 35 assertions), run in production on 2026-09-11. The client
half is `6e0d9b0` plus the arrow and the ghost below.

Done in `0019`:

- **A turn is two activations.** One activation is one unit's whole go — move,
  then strike, or either alone — and each unit gets at most one per turn, so a
  turn is two *different* units doing something real. Jared's answers: move +
  strike is ONE go, and a unit cannot go twice. The opening player's first turn
  is one activation, not two.
- `cn_begin_act` is the only place the budget is charged, so `cn_move`,
  `cn_attack` and `cn_defend` cannot disagree about what a go costs. State
  carries `acts` (spent this turn) and `active` (the unit mid-go); units carry
  `spent`. Matches already in flight read all three through `coalesce`.
- **Defend**: `submit_defend` raises a guard that halves incoming damage until
  that unit's own next turn — so it is still up while the opponent swings, which
  is the only time it could matter. It costs an activation and ends it. This is
  the first thing to pass `cn_damage`'s `p_defending` anything but false; the
  hook has been sitting there unused since 0018.
- **Wait**: `submit_wait` closes an activation for a unit that moved and does
  not want to strike. Without it a go stays open and the menu has no Cancel.
- "End turn" already worked at any time and still does.
- Board → **8 tall × 6 wide**. The halves are rows again: host holds 0–3, guest
  4–7. Nothing is rotated in the database — the CLIENT flips per player, which
  is the part still to build. `cn_own_side` was dropped and recreated rather
  than replaced, because its parameters now mean y and h (the same reason 0011
  dropped `cn_own_half`).
- **4 trees per side**, none on either home row — which subsumes the
  no-corners rule, since every corner sits in a home row. `10_board.sql` rolls
  the generator a hundred times rather than once, because the placement is
  random and a rule that holds for one layout and not the next is the bug worth
  catching.
- **The bot plays by it.** It always *was* bound — it calls the same `cn_*`
  functions and they refused it — but `bot_step` kept proposing a third action
  until the server raised, which is how 06 and 07 found this. It now skips spent
  units and, once the budget is gone, considers only the unit already mid-go.

**The client half is DONE too.** Three things landed:

- **The action menu.** Clicking one of your units opens Move / Attack / Ability
  / Defend / (Wait) / Cancel on the piece itself, and NOTHING is lit until you
  choose. That last part is the real change: the board used to light the move
  tiles and the crosshairs the instant you selected a unit, which made a tile
  and a target look like alternatives when they are two halves of one go.
  Ability is present and disabled -- leaving the slot out until abilities exist
  would move the other four items under the player's thumb on the day they land.
  Wait appears only for the unit already mid-go, because `submit_wait` takes no
  unit and ends whichever one the SERVER has open. Walking does not close the
  menu: it comes straight back, standing where the unit now stands, with Move
  greyed and the rest still there.
- **The board flip**, in `draw()` / `flipFor()` in `rules.ts`. Here is the part
  that reads backwards until you check the rows: it is the **HOST** who flips,
  not the guest. `cn_own_side` gives the host rows 0-3, so drawn straight the
  host is along the TOP and the guest is already at the bottom where they
  belong. A spectator flips nothing, and the tinted half is therefore always the
  NEAR half rather than "yours" -- which is the honest reading for somebody who
  has no side. It is a half turn and not a mirror: flipping only the rows would
  leave left and right alone, and a spearman advancing up the right of the board
  for one player would be advancing up the left of it for the other.
  Two places convert a coordinate for the screen -- `Board.tsx`, and the hovered
  tree's card in `Match.tsx` -- and both go through `flipFor()`, which is why
  the rule is named rather than written out twice.
- **The goes**, as two rhomboid pips in the turn bar beside the clock, plus the
  count in the hint under the board. One pip on the opening turn, because that
  turn really does have one activation. Nothing on screen used to say this, so
  the server's refusal was the first you heard of the rule.

Also: `spent` and `defending` reach the token. A spent unit greys out -- the
PICTURE greys, not the whole token, or the shield on a defending unit would be
invisible on every unit it matters for -- and a raised guard shows a shield in
the upper left, stacking rightward past the burn icon the way the roster spec
asks for.

**Order of operations, and it matters: `0019` has to be run in production BEFORE
this client is deployed.** The client reads `acts` / `active` / `spent`, calls
`submit_defend` and `submit_wait`, and reads the halves as rows. On a database
still at `0018` those two functions do not exist and the board is still 8 wide
by 6 tall, so Defend and Wait would error and the tints would be drawn across
the wrong axis.

And the last two client pieces, which finish Phase B:

- **The movement arrow.** `pathTo()` in `rules.ts` is `reachable()`'s walk again
  with a predecessor kept for each tile, so the two cannot disagree about where
  a unit may go -- the arrow is a promise about a click and the server keeps or
  breaks it using those rules. Breadth first, so the first route to a tile is a
  shortest one. A flier gets the straight hop, because it is not walking.
  It is drawn Fire Emblem's way: **one piece of arrow per tile**, each an
  ordinary grid item in its own cell, built as "in-edge to middle to out-edge"
  so the straight, the corner, the tail and the shaft of the head are all the
  same two lines with different ends. No pixel arithmetic anywhere -- which is
  deliberate, since screen-rectangle maths is what broke FLIP and the board
  height before. It shows only while Move is the open question.
- **The opponent's pointer**, in `useGhost.ts`. A Realtime BROADCAST channel,
  no database, no migration. Three small fields travel -- the tile under their
  pointer, the unit they picked up, and which menu item they are on -- and the
  receiving client RECOMPUTES the highlights from the shared state with the
  same `reachable()` / `targetsFor()` everything else uses. Sending tiles would
  be more bytes and would go stale in flight.
  Its security model is that none of it is a fact about the game: a cheater can
  lie about where their mouse is, and the prize is that you get a wrong idea
  about where their mouse is. **What must never reach it** is the part to keep
  an eye on, and there are two things: it does not run during **deployment**
  (the half-boards are deliberately unreadable to each other, and a pointer
  would give a setup away one square at a time), and when Mist lands a Rogue
  aiming from inside it must go quiet -- `mute` is the argument waiting for
  that. It is also off against the bot, which has no pointer.

Nothing of Phase B is left.

### Phase C — the battle cinematic

**Phase C is DONE.** The server half is `0020_swings.sql` and
`0021_cinematic_clock.sql` (`11_swings.sql` 38 assertions, `12_clock.sql` 18),
both run in production on 2026-09-11. The client half is `cine.ts` and
`Duel.tsx`.

Jared's two answers that shaped this: the cinematic is a **full takeover** of
the screen, and **the turn clock is paused for it**. There is no off switch for
now -- a full/quick/off setting was offered and deferred to Phase D with the
rest of the settings work.

What `0020` does, and what it deliberately does not: it changes **no rule**.
Not one number is computed differently and no branch is taken differently --
which is why `09_combat.sql` and `10_board.sql` still pass untouched at 63 and
35. All it does is write down what `cn_attack` was already deciding and
throwing away.

The problem it solves is that `fx` reported **sums**, and sums cannot be
un-added. `dmg 30, counter 45, parries 2, chain 4` has many different fights
behind it, and a cinematic built on a guess about which one would narrate blows
that never landed. So the swings are kept in the order they happened and go out
on `fx.swings`. A swing is:

| field | |
|---|---|
| `k` | `hit` / `parry` / `burn` / `down` / `heal` |
| `by`, `at` | unit ids (a tree's id where the target is a tree) |
| `dmg` | what it took off |
| `crit` | the 5% roll came up |
| `counter` | it was an answer, so it was halved |
| `def` | the receiver had a guard up, so it was halved again |
| `first` | it landed BEFORE the blow it answers — Quick Dagger, and only that |
| `why` | `strike` / `counter` / `quick` / `tree` / `mend`, or for a parry `roll` / `all` |

`why` on a parry is the one worth keeping: Lium catching an answer because he
is Lium is not the same event as a 5% roll coming up, and a caption that calls
both of them "parries" is labelling rather than narrating.

`cn_attack` in `0020` is `0019`'s definition with the recording spliced in,
copied out programmatically rather than retyped -- 330 lines of combat rules is
not where to find out whether the `deploy_unit` lesson took.

The test file also pinned down two things worth writing down, because both read
like bugs until you follow the rules through:

- **Lium's catch earns him a free blow.** Catching an answer is a parry, a
  parry answers if the parrier can reach what it caught, and he is standing
  next to it -- so the shape is `hit, parry, hit`, three swings, and the third
  is his. It lands in `riposte`, not `counter`.
- A killed unit leaves the board for good, so the section that kills somebody
  has to kill a unit no later section needs. `09_combat.sql` already had to
  learn this; `11_swings.sql` now does the same thing for the same reason.

### What `0021` does

The cinematic is two to six seconds of a thirty-second turn, so left alone it
would be charged to the attacker's thinking time and the correct way to play
would be to turn it off. A cinematic you are penalised for watching is not a
feature. So `submit_attack` pushes the deadline by exactly `cn_cine_ms()` of
the swings that were just recorded.

Three things about that, each load-bearing:

- **It is in `submit_attack`, not `cn_attack`.** `cn_attack` holds the rules and
  the bot calls it directly; the bot has no screen and no clock, and giving it
  seconds would be giving it nothing. The turn clock is already `submit_*`'s
  business -- that is where "your time ran out" is raised.
- **There is no "give me more time" call to abuse.** The length is computed
  from the server's own record of the fight. The only way to buy a second is to
  make the server play a longer fight, and the only way to do that is to have
  one. Moving and defending buy nothing, and `12_clock.sql` asserts it.
- **It is capped at twelve seconds**, comfortably above the longest fight that
  can happen today (an eight-parry chain), because abilities are coming and one
  that swings fifty times should not hand its owner a minute to think in.

`cn_cine_ms` is mirrored in the client as `cineMs()` in `src/lib/cine.ts`. The
two have to agree: the server is buying time for a picture the client is
drawing, and if the client's picture runs longer than the server's budget the
player loses their turn watching it. Change a beat length in one, change it in
the other.

### The client half

`src/lib/cine.ts` turns the server's record into a **timeline** -- beats with a
clock, a running health total and a sentence each -- and decides nothing. All
of it is pure: no React, no DOM, no clock of its own, which is what lets four
hundred random fights be checked in node rather than in a browser.

`src/components/Duel.tsx` walks that timeline. It takes the whole screen, the
two of them float and lunge, the health drains, a caption box says what
happened and which rule made it happen, and it is skippable on any click or
key.

Things in there that are load-bearing and look like style until they are not:

- **Health is walked FORWARD from a snapshot taken before the exchange**, never
  back-calculated from what survived. Back-calculation works for the living and
  silently invents a number for the dead -- and the dead are what the last beat
  is about. `Board.tsx` is where the cinematic is built for exactly this
  reason: it already keeps the board a moment ago, because a killed unit is
  gone from `state.units` by the time the fx arrives.
- **Almost nothing is a CSS animation on a class.** A CSS animation starts when
  its class arrives and does NOT restart if the class is already there -- and
  consecutive beats of the same kind are the normal case, not the edge one: a
  parry chain is eight parries in a row. So the lunge, the fall and the camera
  shake go through the Web Animations API, and the parry flash, the ring and
  the damage number are keyed by the beat so React hands each one a fresh
  element. The board's FLIP animation is driven this way for the same reason.
- **Exchanges are QUEUED, not replaced.** The bot acts every 650ms and a fight
  takes seconds, so without a queue its second activation would cut its first
  fight off and show you the aftermath of one you never saw. `Board` also
  reports `onWatching`, and `Match` holds the bot back while a fight is on
  screen.
- **`onDone` is held in a ref and kept out of the schedule's dependencies**, and
  the parent's callback is stable as well. A fresh arrow on any re-render would
  tear down every timer and restart the cinematic from the top -- the blank
  rematch page wearing a different hat.
- Hitstop is **inside** a beat rather than added to it, so it costs no clock and
  cannot accumulate.

Still to build, and deliberately left:

- **Per-ability animations** (the fireball travelling, and so on) and
  status-effect animations. Abilities do not exist yet; they arrive with the
  roster rework, and the beat kinds in `cine.ts` are where they will hang.
- A **full / quick / off setting**. Offered and deferred to Phase D with the
  rest of the settings work. Fire Emblem itself ships one, and by turn forty of
  a long match the case for it will make itself.

### Phase D — UI, i18n, kingdoms

Phase D is thirteen loosely-related items rather than one chunk, so it is being
built in slices. Jared picked the order: **settings plumbing and dark mode
first**, because the dark-mode toggle and the language toggle both need
somewhere per-account to live, and doing it first stops the other two each
inventing their own storage.

#### DONE: settings per account, and dark mode

**`0022_settings.sql` is built and tested (`13_settings.sql`, 32 assertions) and
NOT yet run in production.** One `profiles.settings` jsonb column, one
`set_settings(patch)` function, one trigger.

The design worth remembering is **known keys are validated, unknown keys are
kept**. Each half prevents a different failure. Drop unknown keys and a client
one deploy ahead of the database loses every new setting silently -- and that
is a NORMAL state here, because the site deploys instantly while migrations are
pasted in by hand. Keep everything unvalidated and a volume of 40 or a theme of
'bananas' comes back as a broken screen on every device rather than only on the
one that wrote it. It is a PATCH rather than a replacement for a related
reason: settings are exactly the thing somebody has open in two tabs.

On the client, **the account is the truth and localStorage is the cache in
front of it**. Writes go local-first and are pushed up debounced and coalesced
(a finger on a volume slider is thirty changes a second); the account's copy
wins when it arrives, and whatever the account is MISSING is pushed up once --
which is how anybody who had settings in a browser before 0022 keeps them.
`settings` is deliberately NOT in `useAuth`'s `REQUIRED_COLUMNS`: a database
that has not run 0022 should still let you play, with the cache doing exactly
what it did before.

**Dark mode.** The theme is resolved in JavaScript and stamped on `<html>` as
`data-theme`, so a CSS rule has exactly one question to ask -- 'system' never
reaches the stylesheet. There is an inline script in `index.html` that reads
the same localStorage cache before first paint, because a white flash in front
of somebody who chose dark is the one thing a dark mode must not do.

Two things the measuring settled, and both went against the first instinct:

- **The side colours do not move between themes.** Lifting `--you` for a dark
  background reads better as a line or a tint, and it wrecked the thing they
  are mostly used for -- a SURFACE with white type on it. White-on-blue went
  from 5.9 to 3.2, worse than the same nameplate in light. So they stay put.
  What a brand colour cannot do on near-black is be small text, which is what
  `--you-ink` is for: the same blue, lifted, used only where the blue IS the
  text.
- **A card's `accent` comes out of the database** and was chosen against white;
  some land at 3.8 on near-black. In dark they are mixed toward the page's ink,
  which keeps the card its own colour and the name readable. Light leaves them
  exactly as the card author set them.

Contrast is measured, not eyeballed: every text node's computed colour against
its effective background, composited through transparency, as a WCAG ratio.
**Dark has zero failures. Light has three** -- `.vs`, `.orline` and `.savemark`
-- and all three predate this work. They are listed in the test rather than
silently tolerated: each is a quiet label the palette deliberately keeps quiet,
and changing them is a decision about the brand rather than about dark mode.
**Still open for Jared**, if he wants them lifted.

#### Still to do in Phase D

- **Spanish** translation toggle. UI strings in repo JSON; ability text in DB
  (`ability_en` / `ability_es`). The Spanish ability text is already written in
  section 6, so nothing is blocked. `lang` is ALREADY a validated key in 0022,
  so this needs no migration of its own.
- A **full / quick / off setting for the cinematic**, which now has a place to
  live.
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

6. ~~What counts as one of the two unit-actions, and can one unit spend both?~~
   **A whole activation — move + strike is one.** And **no**: two different
   units. Both built in `0019`.

Nothing is open, and Phase C is finished. The next piece of work is **Phase D**
-- dark mode, settings saved per account, Spanish, kingdoms, the card editor --
which is also where the cinematic's full/quick/off setting belongs.

One thing is waiting on Jared rather than on code: the site has to be
**deployed** for any of the Phase C client to be visible. `./deploy.sh` from an
ordinary terminal. Everything it needs is already live in the database.
