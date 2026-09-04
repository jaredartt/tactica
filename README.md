# Crown Nemesis

A 1v1 turn-based tactics card game that runs in the browser. Accounts, hosted
rooms, live spectating, in-match chat, a battle log, and a 30-second turn clock.

This is the **multiplayer skeleton with a deliberately simple battle inside
it**. The networking, auth, room lifecycle, turn ownership and clock are the
parts that are expensive to change later, so they are built properly. The
combat rules are a placeholder you should expect to throw away.

---

## This project is already set up

The Supabase project exists, the schema is applied, and `.env.local` is written
on the machine this was set up from. To run it:

```bash
npm install
npm run dev
```

Then open <http://localhost:5173>, create an account, hit **Host a room**, and
send the 5-letter code to a friend. To see both sides yourself, open a second
browser in a private window and make a second account.

| | |
|---|---|
| Supabase project | `tactica`, Central EU (Frankfurt), free tier |
| Project ref | `dnhvfajvfhmqpbwfvyfq` |
| Repo | `jaredartt/tactica` (private) |

`.env.local` holds the project URL and the **publishable** key. That key is
meant to be public — it ships to every visitor's browser, and Row Level
Security is what actually constrains it. A `service_role` / secret key must
never go in that file or in this repo.

### Two things to change before you promote this publicly

1. **Email confirmation is OFF** (Authentication → Sign In / Providers). It was
   disabled so you and a friend could make test accounts without waiting on
   Supabase's free-tier email throttle. Turn it back on before strangers can
   sign up, or people will register addresses they don't own.
2. **Chat is unmoderated and unrated-limited.** Add a per-user rate limit before
   this reaches a Discord.

### Setting up a second Supabase project from scratch

If you ever need to rebuild this (a new environment, or you delete the project):
create a project at supabase.com, paste `supabase/migrations/0001_init.sql`
into its SQL editor and run it, then copy the project URL and publishable key
from Project Settings → API into `.env.local` — see `.env.example`.

### It is deployed

**https://jaredartt.github.io/tactica/** — open it on any device, phone included.

Served by GitHub Pages from the `gh-pages` branch, which holds the built
output only. The repo is public because Pages requires that on the free plan;
nothing secret is in it. The publishable key is compiled into the bundle,
which is what that key is for — Row Level Security is the thing actually
protecting your data.

To ship a change:

```bash
./deploy.sh
```

That builds and force-pushes `dist/` to `gh-pages`. The live site updates about
a minute later. Needs Node, so until Node is installed on this Mac, ask Claude
to run it.

### Running it locally instead

Needs Node on the machine itself (nodejs.org, LTS, the .pkg installer — it
asks for your Mac password). Then `npm install && npm run dev` and
<http://localhost:5173>. The dev server is much faster to iterate against than
redeploying, so it is worth doing once you are changing code often.

---

## The one architectural decision worth understanding

**The database owns the game state. The browser only asks.**

There is no update policy on the `matches` table. None. A client physically
cannot write to it. Every action goes through a Postgres function that
re-checks, server-side:

- is the match actually running
- are *you* one of the two players (spectators are rejected here)
- is it *your* turn
- has your 30 seconds actually expired
- can that specific unit legally do that specific thing

If any check fails the function raises and nothing changes. This costs nothing
on the free tier — no game server, no edge functions — and it means you never
have to trust the client. It also means that when you rewrite the combat rules
(and you will), you rewrite them in *one* place and both players get the new
rules at the same instant.

**The turn clock works the same way.** Nothing is polling on a server. Every
connected browser — both players *and* spectators — watches the deadline and,
once it passes, calls `force_timeout()`. That function checks Postgres's own
clock and refuses if time actually remains. So it doesn't matter who calls it,
how many call it at once, or whether someone's laptop clock is wrong.

### State shape

The whole board lives in one `jsonb` column, `matches.state`:

```jsonc
{
  "v": 1,
  "board": { "w": 7, "h": 5 },
  "turn": "host",              // whose turn: "host" | "guest"
  "turnNumber": 4,
  "units": [ { "id": "h1", "owner": "host", "name": "Vanguard",
               "hp": 14, "maxHp": 14, "atk": 4, "mov": 3, "rng": 1,
               "x": 0, "y": 1, "moved": false, "acted": false } ],
  "log": [ { "n": 1, "turn": 1, "text": "Vanguard advances." } ],
  "winner": null
}
```

One blob means one realtime message moves the board *and* the battle log
together, so they can never disagree. It also means changing the game means
changing a shape, not a schema.

### Current placeholder rules

Deliberately thin. 7×5 grid, two units a side, mirrored so it's fair. Per
turn each of your units may move once (Manhattan distance ≤ its `mov`, no
stacking) and attack once (Manhattan distance ≤ its `rng`, damage = `atk`,
flat). Attacking ends that unit's turn. Lose all units and you lose. 30
seconds a turn, then it passes automatically.

---

## Testing the rules

```bash
./supabase/tests/run.sh
```

Spins up a throwaway local Postgres (needs `postgresql` installed locally),
applies the real migration, and plays a whole match through the real functions
— asserting turn order, move range, board bounds, unit stacking, the clock,
spectator limits, and the security policies. It does not touch your Supabase
project. Add a case here whenever you add a rule; it is much faster than
finding out from a player.

---

## Project layout

```
supabase/migrations/0001_init.sql   schema, RLS policies, and ALL game rules
supabase/tests/                     the rules, played out and asserted
src/lib/api.ts                      thin wrappers over the Postgres functions
src/lib/useMatch.ts                 realtime + poll fallback + server clock
src/components/Board.tsx            the tilted arena and the unit cards
src/components/Match.tsx            layout, turn clock, timeout enforcement
src/styles.css                      the whole look
```

---

## Not built yet (in the order I'd do them)

1. **Admin card panel.** The `cards` table, its RLS policy and the `is_admin`
   flag already exist and already feed every match. What's missing is the UI.
   To make yourself an admin, run this once in the Supabase SQL editor:
   `update profiles set is_admin = true where username = 'YOUR_NAME';`
   (You cannot do it from the app — a trigger blocks self-promotion.)
2. **Deck building.** A `decks` table and a deck picker in the lobby, then
   `create_match` draws from each player's chosen deck instead of two random
   cards.
3. **Card art upload.** Supabase Storage bucket, admin-write / public-read.
   `cards.art_url` is already wired through to the board.
4. **Real mechanics.** Terrain, facing, abilities, initiative — whatever the
   game turns out to be. This is the part that should change the most.
5. **Reconnect polish, rematch button, match history.**

## Deliberate limitations

- The board does not flip for the guest; both players see the host on the
  left. Fine for now, worth revisiting when the map gets bigger.
- Abandoned rooms stay in the table. Once you have real traffic, add a
  scheduled job to close matches idle for more than an hour.
- Chat is unmoderated and unfiltered. Before you put this in front of a
  Discord, add at minimum a per-user rate limit.
